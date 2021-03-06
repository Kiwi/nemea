#lang racket/base

(require component
         db
         db/util/postgresql
         gregor
         gregor/period
         koyo/database
         racket/async-channel
         racket/contract/base
         racket/function
         racket/match
         racket/set
         retry
         threading
         (prefix-in config: "../config.rkt")
         "geolocator.rkt"
         "page-visit.rkt")

(provide
 (contract-out
  [struct batcher ([database database?]
                   [geolocator geolocator?]
                   [events async-channel?]
                   [timeout exact-positive-integer?]
                   [listener-thread (or/c false/c thread?)])]

  [make-batcher (->* ()
                     (#:channel-size exact-positive-integer?
                      #:timeout exact-positive-integer?)
                     (-> database? geolocator? batcher?))]

  [enqueue (-> batcher? page-visit? void?)]))

(define-logger batcher)

(struct batcher (database geolocator events timeout listener-thread)
  #:property prop:evt (struct-field-index listener-thread)
  #:methods gen:component
  [(define (component-start a-batcher)
     (log-batcher-debug "starting batcher")
     (struct-copy batcher a-batcher
                  [listener-thread (thread (make-listener a-batcher))]))

   (define (component-stop a-batcher)
     (log-batcher-debug "stopping batcher")
     (!> a-batcher 'stop)
     (thread-wait (batcher-listener-thread a-batcher))
     (struct-copy batcher a-batcher
                  [listener-thread #f]))])

(define ((make-batcher #:channel-size [channel-size 500]
                       #:timeout [timeout 60]) database geolocator)
  (batcher database geolocator (make-async-channel channel-size) timeout #f))

(define (!> batcher event)
  (async-channel-put (batcher-events batcher) event))

(define (enqueue batcher page-visit)
  (define date (today #:tz config:timezone))
  (async-channel-put (batcher-events batcher) (list date page-visit)))

(define (log-exn-retryer)
  (retryer #:handle (lambda (r n)
                      (log-batcher-error "retrying error:\n~a\nattempt: ~a" (exn-message r) n))))

(define upsert-retryer
  (retryer-compose (cycle-retryer (sleep-exponential-retryer (seconds 1)) 8)
                   (sleep-const-retryer/random (seconds 5))
                   (log-exn-retryer)))

(define ((make-listener batcher))
  (define timeout (* (batcher-timeout batcher) 1000))
  (define geolocator (batcher-geolocator batcher))
  (define events (batcher-events batcher))
  (define init (list (set) (set) 0))

  (let loop ([batch (hash)])
    (sync
     (choice-evt
      (handle-evt
       events
       (lambda (event)
         (match event
           ['stop
            (log-batcher-debug "received 'stop")
            (call/retry upsert-retryer (lambda () (upsert-batch! batcher batch)))
            (void)]

           ['timeout
            (log-batcher-debug "received 'timeout")
            (call/retry upsert-retryer (lambda () (upsert-batch! batcher batch)))
            (loop (hash))]

           [(list d pv)
            (define k (grouping d
                                (url->canonical-host (page-visit-location pv))
                                (url->canonical-path (page-visit-location pv))
                                (and~> (page-visit-referrer pv) (url->canonical-host))
                                (and~> (page-visit-referrer pv) (url->canonical-path))
                                (and~>> (page-visit-client-ip pv) (geolocator-country-code geolocator))))
            (loop (hash-update batch k (curry aggregate pv) init))])))

      (handle-evt
       (alarm-evt (+ (current-inexact-milliseconds) timeout))
       (lambda (e)
         (async-channel-put events 'timeout)
         (loop batch)))))))

(define/match (aggregate pv agg)
  [(_ (list visitors sessions visits))
   (list (set-add visitors (page-visit-unique-id pv))
         (set-add sessions (page-visit-session-id pv))
         (add1 visits))])

(define (upsert-batch! batcher batch)
  (with-database-transaction [conn (batcher-database batcher)]
    (for ([(grouping agg) (in-hash batch)])
      (match-define (list visitors sessions visits) agg)
      (query-exec conn UPSERT-BATCH-QUERY
                  (->sql-date (grouping-date grouping))
                  (grouping-host grouping)
                  (grouping-path grouping)
                  (or (grouping-referrer-host grouping) "")
                  (or (grouping-referrer-path grouping) "")
                  (or (grouping-country-code grouping) "ZZ")
                  visits
                  (list->pg-array (set->list visitors))
                  (list->pg-array (set->list sessions))))))

(define UPSERT-BATCH-QUERY
  #<<SQL
with
  visitors_agg as (select hll_add_agg(hll_hash_text(s.x)) as visitors from (select unnest($8::text[]) as x) as s),
  sessions_agg as (select hll_add_agg(hll_hash_text(s.x)) as sessions from (select unnest($9::text[]) as x) as s)
insert into page_visits(date, host, path, referrer_host, referrer_path, country_code, visits, visitors, sessions)
  values($1, $2, $3, $4, $5, $6, $7, (select visitors from visitors_agg), (select sessions from sessions_agg))
on conflict on constraint page_visits_partition
do update
  set
    visits = page_visits.visits + $7,
    visitors = page_visits.visitors || (select visitors from visitors_agg),
    sessions = page_visits.sessions || (select sessions from sessions_agg)
  where
    page_visits.date = $1 and
    page_visits.host = $2 and
    page_visits.path = $3 and
    page_visits.referrer_host = $4 and
    page_visits.referrer_path = $5 and
    page_visits.country_code = $6
SQL
  )

(struct grouping (date host path referrer-host referrer-path country-code)
  #:transparent)


(module+ test
  (require net/url
           rackunit
           rackunit/text-ui
           "migrator.rkt")

  (define-system test
    [database (make-database-factory
               (lambda _
                 (postgresql-connect
                  #:database "nemea_tests"
                  #:user     "nemea"
                  #:password "nemea")))]
    [batcher (database geolocator) (make-batcher)]
    [geolocator make-geolocator]
    [migrator (database) make-migrator])

  (run-tests
   (test-suite
    "Batcher"
    #:before
    (lambda ()
      (system-start test-system)
      (with-database-connection [conn (system-get test-system 'database)]
        (query-exec conn "truncate page_visits")))

    #:after
    (lambda ()
      (system-stop test-system))

    (test-case "upserts visits"
      (enqueue (system-get test-system 'batcher) (page-visit "a" "b" (string->url "http://example.com/a") #f #f))
      (enqueue (system-get test-system 'batcher) (page-visit "a" "c" (string->url "http://example.com/a") #f #f))
      (!> (system-get test-system 'batcher) 'timeout)
      (sync (system-idle-evt))

      (check-equal?
       (with-database-connection [conn (system-get test-system 'database)]
         (query-row conn "select visits, hll_cardinality(visitors), hll_cardinality(sessions) from page_visits order by date desc limit 1"))
       #(2 1.0 2.0))

      (enqueue (system-get test-system 'batcher) (page-visit "a" "b" (string->url "http://example.com/a") #f #f))
      (enqueue (system-get test-system 'batcher) (page-visit "a" "b" (string->url "http://example.com/a") #f #f))
      (enqueue (system-get test-system 'batcher) (page-visit "a" "b" (string->url "http://example.com/b") #f #f))
      (!> (system-get test-system 'batcher) 'stop)
      (sync (system-get test-system 'batcher))

      (check-eq?
       (with-database-connection [conn (system-get test-system 'database)]
         (query-value conn "select visits from page_visits where path = '/a' order by date desc limit 1"))
       4)

      (check-eq?
       (with-database-connection [conn (system-get test-system 'database)]
         (query-value conn "select visits from page_visits where path = '/b' order by date desc limit 1"))
       1)))))

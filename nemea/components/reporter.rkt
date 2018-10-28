#lang racket/base

(require db
         gregor
         racket/contract
         "database.rkt"
         "system.rkt"
         "utils.rkt")

(provide (contract-out
          (struct reporter ((database database?)))
          (make-reporter (-> database? reporter?))
          (make-daily-report (-> reporter? date? date? (listof hash?)))))

(struct reporter (database)
  #:methods gen:component
  [(define (component-start reporter) reporter)
   (define (component-stop reporter) (void))])

(define (make-reporter database)
  (reporter database))

(define DAILY-REPORT-QUERY
  #<<SQL
select
  date, path, referrer_host, visits
from
  page_visits
where
  date >= $1 and
  date < $2
order by date, path
SQL
)

(define (make-daily-report reporter start-date end-date)
  (define conn (database-connection (reporter-database reporter)))
  (for/list ([(d path referrer-host visits)
              (in-query conn DAILY-REPORT-QUERY (date->sql-date start-date) (date->sql-date end-date))])

    (hasheq 'date (sql-date->date d)
            'path path
            'referrer-host referrer-host
            'visits visits)))

(module+ test
  (require rackunit
           rackunit/text-ui
           "migrations.rkt")

  (define test-system
    (make-system `((database ,(make-database #:database "nemea_tests"
                                             #:username "nemea"
                                             #:password "nemea"))
                   (migrations [database] ,make-migrations)
                   (reporter [database] ,make-reporter))))

  (run-tests
   (test-suite
    "reporter"
    #:before
    (lambda ()
      (system-start test-system)

      (query-exec (database-connection (system-get test-system 'database)) "truncate page_visits")
      (query-exec
       (database-connection (system-get test-system 'database))
       #<<SQL
insert into
  page_visits(date, path, referrer_host, referrer_path, country, os, browser, visits)
values
  ('2018-08-20', '/', '', '', '', '', '', 10),
  ('2018-08-20', '/a', '', '', '', '', '', 1),
  ('2018-08-20', '/b', '', '', '', '', '', 2),
  ('2018-08-21', '/a', '', '', '', '', '', 3),
  ('2018-08-21', '/b', '', '', '', '', '', 5),
  ('2018-08-23', '/a', '', '', '', '', '', 1),
  ('2018-08-23', '/b', '', '', '', '', '', 2),
  ('2018-08-24', '/', '', '', '', '', '', 1)
SQL
       ))

    #:after (lambda () (system-stop test-system))

    (test-case "builds daily reports"
      (check-equal?
       (make-daily-report
        (system-get test-system 'reporter)
        (date 2018 8 20)
        (date 2018 8 24))
       (list (hasheq 'date (date 2018 8 20) 'path "/" 'referrer-host "" 'visits 10)
             (hasheq 'date (date 2018 8 20) 'path "/a" 'referrer-host "" 'visits 1)
             (hasheq 'date (date 2018 8 20) 'path "/b" 'referrer-host "" 'visits 2)
             (hasheq 'date (date 2018 8 21) 'path "/a" 'referrer-host "" 'visits 3)
             (hasheq 'date (date 2018 8 21) 'path "/b" 'referrer-host "" 'visits 5)
             (hasheq 'date (date 2018 8 23) 'path "/a" 'referrer-host "" 'visits 1)
             (hasheq 'date (date 2018 8 23) 'path "/b" 'referrer-host "" 'visits 2)))))))
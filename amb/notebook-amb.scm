
;;; Code written by Oleg Kiselyov
;; (http://pobox.com/~oleg/ftp/)
;;;
;;; Taken from leanTAP.scm
;;; http://kanren.cvs.sourceforge.net/kanren/kanren/mini/leanTAP.scm?view=log

; A simple linear pattern matcher
; It is efficient (generates code at macro-expansion time) and simple:
; it should work on any R5RS Scheme system.

; (pmatch exp <clause> ...[<else-clause>])
; <clause> ::= (<pattern> <guard> exp ...)
; <else-clause> ::= (else exp ...)
; <guard> ::= boolean exp | ()
; <pattern> :: =
;        ,var  -- matches always and binds the var
;                 pattern must be linear! No check is done
;         _    -- matches always
;        'exp  -- comparison with exp (using equal?)
;        exp   -- comparison with exp (using equal?)
;        (<pattern1> <pattern2> ...) -- matches the list of patterns
;        (<pattern1> . <pattern2>)  -- ditto
;        ()    -- matches the empty list

; Modified by Adam C. Foltzer for R6RS compatibility

(define-syntax pmatch
  (syntax-rules (else guard)
    ((_ (rator rand ...) cs ...)
     (let ((v (rator rand ...)))
       (pmatch v cs ...)))
    ((_ v) (error 'pmatch "failed: ~s" v))
    ((_ v (else e0 e ...)) (begin e0 e ...))
    ((_ v (pat (guard g ...) e0 e ...) cs ...)
     (let ((fk (lambda () (pmatch v cs ...))))
       (ppat v pat (if (and g ...) (begin e0 e ...) (fk)) (fk))))
    ((_ v (pat e0 e ...) cs ...)
     (let ((fk (lambda () (pmatch v cs ...))))
       (ppat v pat (begin e0 e ...) (fk))))))

(define-syntax ppat
  (syntax-rules (uscore quote unquote)
    ((_ v uscore kt kf)
     ; _ can't be listed in literals list in R6RS Scheme
     (and (identifier? #'uscore) (free-identifier=? #'uscore #'_))
     kt)
    ((_ v () kt kf) (if (null? v) kt kf))
    ((_ v (quote lit) kt kf) (if (equal? v (quote lit)) kt kf))
    ((_ v (unquote var) kt kf) (let ((var v)) kt))
    ((_ v (x . y) kt kf)
     (if (pair? v)
       (let ((vx (car v)) (vy (cdr v)))
	 (ppat vx x (ppat vy y kt kf) kf))
       kf))
    ((_ v lit kt kf) (if (equal? v (quote lit)) kt kf))))

;;; A nestable procedure that returns the first argument to finish evaluation


(define in-amb? #f)

(define-syntax amb
   (syntax-rules ()
     [(_ t1 t2)
      (amb-core (lambda () t1) (lambda () t2))]))

(define mcall/cc
  (lambda (f)
    (call/cc (lambda (k)               
               (engine-return 'kont `(in-engine ,k) f)))))

(define-syntax call/cc
  (syntax-rules ()
    [(_ arg)
     (if in-amb?
         (mcall/cc arg)
         (call-with-current-continuation arg))]))

(define-syntax rcc
  (syntax-rules ()
    [(_ arg) (call-with-current-continuation arg)]))
         
 (define amb-core
   (lambda (t1 t2)
     (rcc (lambda (k)
                (if in-amb?
                    (engine-return 'amb `(in-engine ,k) `(thunk ,t1) `(thunk ,t2))
                    (begin (fluid-let ([in-amb? #t])
                           (run-amb `(amb (jumpout ,k) (thunk ,t1) (thunk ,t2))))))))))

(define run-amb
   (lambda (tree)
     (run-amb (iter tree))))

(define iter
  (lambda (tree)
    (pmatch tree
     [(amb ,context ,t1 ,t2)
      (let* ([jump (lambda (context value)
                     (pmatch context
                       [(jumpout ,context) (context value)]
                       [(in-engine ,context)
                        ((make-engine (lambda () (context value))) 1
                         (lambda (ticks value) `(val ,value))
                         (lambda (x) `(eng ,x)))]
                       [(doublec ,c1 ,c2)
                        ((make-engine (lambda () (c1 (c2 value)))) 1
                                     (lambda (ticks value) `(val value))
                                     (lambda (x) `(eng ,x)))]))]
             [run-eng (lambda (eng)
                        (eng 1 (lambda in (pmatch in
                            [(,ticks amb ,context ,t1 ,t2) `(amb ,context ,t1 ,t2)]
                            [(,ticks akont ,k ,arg) (k arg)]
                            [(,ticks kont ,context2 ,body) (rcc (lambda (k)
                                `(eng ,(make-engine (lambda ()
                                    ((cadr context2) (body (lambda (arg)
                                        (if in-amb?
                                            (engine-return 'akont (lambda (a) (jump `(doublec ,(cadr context) ,(cadr context2)) a)) arg)
                                            (k (jump context2 arg)))))))))))]
                            [(,ticks ,value) `(val ,value)]))
                             (lambda (x) `(eng ,x))))]
             [run (lambda (exp)
                    (pmatch exp
                      [(thunk ,t) (run-eng (make-engine t))]
                      [(amb ,context ,t1 ,t2) (iter exp)]
                      [(eng ,e) (run-eng e)]))])
        (let ([r1 (run t1)] [r2 (run t2)])
          (pmatch `(,r1 ,r2)
            [((val ,v1) ,r2) (jump context v1)]
            [(,r1 (val ,v2)) (jump context v2)]
            [(,r1 ,r2) `(amb ,context ,r1 ,r2)])))])))



(define omega
  (lambda ()
    ((lambda (x) (x x)) (lambda (x) (x x)))))

(define test1
  (lambda ()
    (+ 5 (amb ((lambda (x) (x x)) (lambda (x) (x x))) (+ 120 (amb 120 ((lambda (x) (x x)) (lambda (x) (x x)))))))))

(define test2
  (lambda ()
    (+ 5 (amb (omega) (+ 5 (amb (omega) (+ 5 (amb (omega) (+ 5 (amb 120 (omega)))))))))))

(define test31
  (lambda ()
    (amb (omega) (+ 5 (call/cc (lambda (k) (set! foo k) 120))))))

(define test32
  (lambda ()
    (foo 1)))

(define test4
  (lambda ()
    (amb ((lambda (x) (map add1 (list 1 2 3 4 5))) 120)
         (call/cc (lambda (k) (omega) (k 1) 120)))))

(define test5
  (lambda ()
    (amb ((lambda (x) (map add1 (list 1 2 3 4 5))) 120)
         (+ (call/cc (lambda (k) (k 1))) (omega)))))

(define test6
  (lambda ()
    (amb ((lambda (x) (map add1 (list 1 2 3 4 5))) 120)
         (+ (omega) (call/cc (lambda (k) (k 1)))))))

(load "../prog/prog.scm")
(define prog-loop
    '(progs goto return (x y z) x^ ()
           (x^
            (set! x (amb (omega) (+ 5 (call/cc (lambda (k) (set! y k) 120))))))
           (y^
            (y x)
            (return x))))


(define prog-inside-amb
  (lambda ()
    (amb
     (progs goto return (x y z) x^ ()
          (x^
           (set! x 5)
           (set! y x))
          (y^
           (set! z (+ 3 y))
           (goto a^))
          (z^
           (return 120))
          (a^
           (return z)))
     
    (omega))))

(define prog-inside-amb2
  (lambda ()
    (amb
     (progs goto return (x y z) x^ ()
          (x^
           (set! x 5)
           (set! y x))
          (y^
           (set! z (+ 3 y))
           (goto a^))
          (z^
           (return 120))
          (a^
           (return z)))
     
    (progs goto return () x^ ()
          (x^
           (goto y^))
          (y^
           (goto x^)
           (return 120))))))

     

(print-gensym 'pretty/suffix)
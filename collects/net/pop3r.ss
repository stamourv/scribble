; Time-stamp: <98/10/09 19:19:06 shriram>

(unit/sig mzlib:pop3^
  (import)

  ;; Implements RFC 1939, Post Office Protocol - Version 3, Myers & Rose

  ;; sender : oport
  ;; receiver : iport
  ;; server : string
  ;; port : number
  ;; state : symbol = (disconnected, authorization, transaction)

  (define-struct communicator (sender receiver server port state))

  (define-struct (pop3 struct:exn) ())
  (define-struct (cannot-connect struct:pop3) ())
  (define-struct (username-rejected struct:pop3) ())
  (define-struct (password-rejected struct:pop3) ())
  (define-struct (not-ready-for-transaction struct:pop3) (communicator))
  (define-struct (not-given-headers struct:pop3) (communicator message))
  (define-struct (illegal-message-number struct:pop3) (communicator message))
  (define-struct (cannot-delete-message struct:exn) (communicator message))
  (define-struct (disconnect-not-quiet struct:pop3) (communicator))
  (define-struct (malformed-server-response struct:pop3) (communicator))

  ;; signal-error :
  ;; (exn-args ... -> exn) x format-string x values ... ->
  ;;   exn-args -> ()

  (define signal-error
    (lambda (constructor format-string . args)
      (lambda exn-args
	(raise (apply constructor
		 (apply format format-string args)
		 (current-continuation-marks)
		 exn-args)))))

  ;; signal-malformed-response-error :
  ;; exn-args -> ()

  ;; -- in practice, it takes only one argument: a communicator.

  (define signal-malformed-response-error
    (signal-error make-malformed-server-response
      "malformed response from server"))

  ;; confirm-transaction-mode :
  ;; communicator x string -> ()

  ;; -- signals an error otherwise.

  (define confirm-transaction-mode
    (lambda (communicator error-message)
      (unless (eq? (communicator-state communicator) 'transaction)
	((signal-error make-not-ready-for-transaction error-message)
	  communicator))))

  ;; default-pop-port-number :
  ;; number

  (define default-pop-port-number 110)

  (define-struct server-responses ())
  (define-struct (+ok struct:server-responses) ())
  (define-struct (-err struct:server-responses) ())

  (define +ok (make-+ok))
  (define -err (make--err))

  ;; connect-to-server :
  ;; string [x number] -> communicator

  (define connect-to-server
    (opt-lambda (server-name (port-number default-pop-port-number))
      (let-values (((receiver sender)
		     (tcp-connect server-name port-number)))
	(let ((communicator
		(make-communicator sender receiver server-name port-number
		  'authorization)))
	  (let ((response (get-status-response/basic communicator)))
	    (cond
	      ((+ok? response) communicator)
	      ((-err? response)
		((signal-error make-cannot-connect
		   "cannot connect to ~a on port ~a"
		   server-name port-number)))))))))

  ;; authenticate/plain-text :
  ;; string x string x communicator -> ()

  ;; -- if authentication succeeds, sets the communicator's state to
  ;; transaction.

  (define authenticate/plain-text
    (lambda (username password communicator)
      (let ((sender (communicator-sender communicator)))
	(send-to-server communicator "USER ~a" username)
	(let ((status (get-status-response/basic communicator)))
	  (cond
	    ((+ok? status)
	      (send-to-server communicator "PASS ~a" password)
	      (let ((status (get-status-response/basic communicator)))
		(cond
		  ((+ok? status)
		    (set-communicator-state! communicator 'transaction))
		  ((-err? status)
		    ((signal-error make-password-rejected
		       "password was rejected"))))))
	    ((-err? status)
	      ((signal-error make-username-rejected
		 "username was rejected"))))))))

  ;; get-mailbox-status :
  ;; communicator -> number x number

  ;; -- returns number of messages and number of octets.

  (define get-mailbox-status
    (let ((stat-regexp (regexp "([0-9]+) ([0-9]+)")))
      (lambda (communicator)
	(confirm-transaction-mode communicator
	  "cannot get mailbox status unless in transaction mode")
	(send-to-server communicator "STAT")
	(apply values
	  (map string->number
	    (let-values (((status result)
			   (get-status-response/match communicator
			     stat-regexp #f)))
	      result))))))

  ;; get-message/complete :
  ;; communicator x number -> list (string) x list (string)

  (define get-message/complete
    (lambda (communicator message)
      (confirm-transaction-mode communicator
	"cannot get message headers unless in transaction state")
      (send-to-server communicator "RETR ~a" message)
      (let ((status (get-status-response/basic communicator)))
	(cond
	  ((+ok? status)
	    (split-header/body (get-multi-line-response communicator)))
	  ((-err? status)
	    ((signal-error make-illegal-message-number
	       "not given message ~a" message)
	      communicator message))))))

  ;; get-message/headers :
  ;; communicator x number -> list (string)

  (define get-message/headers
    (lambda (communicator message)
      (confirm-transaction-mode communicator
	"cannot get message headers unless in transaction state")
      (send-to-server communicator "TOP ~a 0" message)
      (let ((status (get-status-response/basic communicator)))
	(cond
	  ((+ok? status)
	    (let-values (((headers body)
			   (split-header/body
			     (get-multi-line-response communicator))))
	      headers))
	  ((-err? status)
	    ((signal-error make-not-given-headers
	       "not given headers to message ~a" message)
	      communicator message))))))

  ;; get-message/body :
  ;; communicator x number -> list (string)

  (define get-message/body
    (lambda (communicator message)
      (let-values (((headers body)
		     (get-message/complete communicator message)))
	body)))

  ;; split-header/body :
  ;; list (string) -> list (string) x list (string)

  ;; -- returns list of headers and list of body lines.

  (define split-header/body
    (lambda (lines)
      (let loop ((lines lines) (header null))
	(if (null? lines)
	  (values (reverse header) null)
	  (let ((first (car lines))
		 (rest (cdr lines)))
	    (if (string=? first "")
	      (values (reverse header) rest)
	      (loop rest (cons first header))))))))

  ;; delete-message :
  ;; communicator x number -> ()

  (define delete-message
    (lambda (communicator message)
      (confirm-transaction-mode communicator
	"cannot delete message unless in transaction state")
      (send-to-server communicator "DELE ~a" message)
      (let ((status (get-status-response/basic communicator)))
	(cond
	  ((-err? status)
	    ((signal-error make-cannot-delete-message
	       "no message numbered ~a available to be deleted" message)
	      communicator message))
	  ((+ok? status)
	    'deleted)))))

  ;; regexp for UIDL responses

  (define uidl-regexp (regexp "([0-9]+) (.*)"))

  ;; get-unique-id/single :
  ;; communicator x number -> string

  (define (get-unique-id/single communicator message)
    (confirm-transaction-mode communicator
      "cannot get unique message id unless in transaction state")
    (send-to-server communicator "UIDL ~a" message)
    (let-values (((status result)
		   (get-status-response/match communicator
		     uidl-regexp
		     ".*")))
      ;; The server response is of the form
      ;; +OK 2 QhdPYR:00WBw1Ph7x7
      (cond
	((-err? status)
	  ((signal-error make-illegal-message-number
	     "no message numbered ~a available for unique id" message)
	    communicator message))
	((+ok? status)
	  (cadr result)))))

  ;; get-unique-id/all :
  ;; communicator -> list(number x string)

  (define (get-unique-id/all communicator)
    (confirm-transaction-mode communicator
      "cannot get unique message ids unless in transaction state")
    (send-to-server communicator "UIDL")
    (let ((status (get-status-response/basic communicator)))
      ;; The server response is of the form
      ;; +OK
      ;; 1 whqtswO00WBw418f9t5JxYwZ
      ;; 2 QhdPYR:00WBw1Ph7x7
      ;; .
      (map (lambda (l)
	     (let ((m (regexp-match uidl-regexp l)))
	       (cons (string->number (cadr m)) (caddr m))))
	(get-multi-line-response communicator))))

  ;; close-communicator :
  ;; communicator -> ()

  (define close-communicator
    (lambda (communicator)
      (close-input-port (communicator-receiver communicator))
      (close-output-port (communicator-sender communicator))))

  ;; disconnect-from-server :
  ;; communicator -> ()

  (define disconnect-from-server
    (lambda (communicator)
      (send-to-server communicator "QUIT")
      (set-communicator-state! communicator 'disconnected)
      (let ((response (get-status-response/basic communicator)))
	(close-communicator communicator)
	(cond
	  ((+ok? response) (void))
	  ((-err? response)
	    ((signal-error make-disconnect-not-quiet
	       "got error status upon disconnect")
	      communicator))))))

  ;; send-to-server :
  ;; communicator x format-string x list (values) -> ()

  (define send-to-server
    (lambda (communicator message-template . rest)
      (apply fprintf (communicator-sender communicator)
	(string-append message-template "~n")
	rest)))

  ;; get-one-line-from-server :
  ;; iport -> string

  (define get-one-line-from-server
    (lambda (server->client-port)
      (read-line server->client-port 'return-linefeed)))

  ;; get-server-status-response :
  ;; communicator -> server-responses x string

  ;; -- provides the low-level functionality of checking for +OK
  ;; and -ERR, returning an appropriate structure, and returning the
  ;; rest of the status response as a string to be used for further
  ;; parsing, if necessary.

  (define get-server-status-response
    (let ((+ok-regexp (regexp "^\\+OK (.*)"))
	   (-err-regexp (regexp "^\\-ERR (.*)")))
      (lambda (communicator)
	(let ((receiver (communicator-receiver communicator)))
	  (let ((status-line (get-one-line-from-server receiver)))
	    (let ((r (regexp-match +ok-regexp status-line)))
	      (if r
		(values +ok (cadr r))
		(let ((r (regexp-match -err-regexp status-line)))
		  (if r
		    (values -err (cadr r))
		    (signal-malformed-response-error communicator))))))))))

  ;; get-status-response/basic :
  ;; communicator -> server-responses

  ;; -- when the only thing to determine is whether the response
  ;; was +OK or -ERR.

  (define get-status-response/basic
    (lambda (communicator)
      (let-values (((response rest)
		     (get-server-status-response communicator)))
	response)))

  ;; get-status-response/match :
  ;; communicator x regexp x regexp -> (status x list (string))

  ;; -- when further parsing of the status response is necessary.
  ;; Strips off the car of response from regexp-match.

  (define get-status-response/match
    (lambda (communicator +regexp -regexp)
      (let-values (((response rest)
		     (get-server-status-response communicator)))
	(if (and +regexp (+ok? response))
	  (let ((r (regexp-match +regexp rest)))
	    (if r (values response (cdr r))
	      (signal-malformed-response-error communicator)))
	  (if (and -regexp (-err? response))
	    (let ((r (regexp-match -regexp rest)))
	      (if r (values response (cdr r))
		(signal-malformed-response-error communicator)))
	    (signal-malformed-response-error communicator))))))

  ;; get-multi-line-response :
  ;; communicator -> list (string)

  (define get-multi-line-response
    (lambda (communicator)
      (let ((receiver (communicator-receiver communicator)))
	(let loop ()
	  (let ((l (get-one-line-from-server receiver)))
	    (cond
	      ((eof-object? l)
		(signal-malformed-response-error communicator))
	      ((string=? l ".")
		'())
	      ((and (> (string-length l) 1)
		 (char=? (string-ref l 0) #\.))
		(cons (substring l 1 (string-length l)) (loop)))
	      (else
		(cons l (loop)))))))))

  ;; make-desired-header :
  ;; string -> desired

  (define make-desired-header
    (lambda (raw-header)
      (regexp
	(string-append
	  "^"
	  (list->string
	    (apply append
	      (map (lambda (c)
		     (cond
		       ((char-lower-case? c)
			 (list #\[ (char-upcase c) c #\]))
		       ((char-upper-case? c)
			 (list #\[ c (char-downcase c) #\]))
		       (else
			 (list c))))
		(string->list raw-header))))
	  ":"))))

  ;; extract-desired-headers :
  ;; list (string) x list (desired) -> list (string)

  (define extract-desired-headers
    (lambda (headers desireds)
      (let loop ((headers headers))
	(if (null? headers) null
	  (let ((first (car headers))
		 (rest (cdr headers)))
	    (if (ormap (lambda (matcher)
			 (regexp-match matcher first))
		  desireds)
	      (cons first (loop rest))
	      (loop rest)))))))

  )
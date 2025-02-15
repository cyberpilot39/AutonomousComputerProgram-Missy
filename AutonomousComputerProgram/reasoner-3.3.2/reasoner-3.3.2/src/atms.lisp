;;; Copyright (C) 2007-2011, 2014 by William Hounslow
;;; This is free software, covered by the GNU GPL (v2)
;;; See http://www.gnu.org/copyleft/gpl.html

(eval-when (:compile-toplevel)
  (declaim (optimize (speed 3) (safety 1) (space 0) (debug 0))))

(defpackage :atms (:use :cl))
(in-package atms)
(eval-when (:execute :compile-toplevel :load-toplevel)
  (export
   '(assumption atms environment
     justification node standard-node false-node temporary-node
     antecedents consequent consequents contradictoryp datum informant
     justifications label name contras assumptions nodes size
     datum-assumption assumed-datum
     make-assumption discard-assumption add-justification
     delete-from-environments
     subsumesp in-p truep union-environments uniquify-environment
     add-consumer consumer execute-consumer execute-consumers
     absorb insert singletonp
     )))

(defclass atms ()
    ((environment-hash-table :initform (make-hash-table :test #'equal)
                             :reader environment-hash-table)
     (environments :initform nil :accessor environments
                   :documentation "Set of all environments, ordered by size.")
     (environment-index :initform nil :accessor environment-index)
     (nogoods :initform nil :accessor nogoods
              :documentation
              "Database of contradictory environments, ordered by size."))
  (:documentation "An assumption-based TMS."))

(defclass environment ()
    ((assumptions :reader assumptions :initarg :assumptions)
     (nodes :initform nil :accessor nodes
            :documentation
            "The set of nodes whose label mentions the environment.")
     (node-added :initform nil :reader node-added
            :documentation
            "Indicates whether any new nodes have appeared recently.")
     (node-for-deletion :initform nil :accessor node-for-deletion
            :documentation
            "Indicates whether there are spent temporary nodes.")
     (contradictory :initform nil :accessor contradictoryp)
     (size :reader size :initarg :size :documentation "Number of assumptions."))
  (:documentation "A set (or, logically, a conjunction) of assumptions."))

(defclass justification ()
    ((informant :accessor informant :initarg :informant
                :documentation
                "A problem-solver-supplied description of the inference.")
     (consequent :reader consequent :initarg :consequent
                 :documentation "The node justified.")
     (antecedents :reader antecedents :initarg :antecedents
                  :documentation "The nodes upon which the inference depends."))
  (:documentation "Describes how a node is derivable from other nodes."))

(defclass node ()
    ((label :initform nil :accessor label
            :documentation "A set of environments.")
     (justifications :initform nil :accessor justifications
                     :documentation "The derivations of the datum.")
     (consequents :initform nil :accessor consequents
                  :documentation
                  "The justifications for which the node is an antecedent.")
     (contradictory :initform nil :accessor contradictoryp))
  (:documentation "Records a problem-solver datum."))

(defclass assumption (node)
    ((name :reader name :initarg :name)
     (serial-number :accessor serial-number
                    :documentation "Unique identifier.")
     (last-serial-number :initform 0 :accessor last-serial-number :allocation :class)
     (contras :initform nil :accessor contras
              :documentation "Assumptions that this is inconsistent with."))
  (:documentation "Designates a decision to assume, without any commitment as to what is assumed."
         ))

(defclass false-node (node)
    ((contradictory :initform t :accessor contradictoryp)))

(defclass standard-node (node)
    ((datum :reader datum :initarg :datum
            :documentation "The problem-solver's representation of a fact.")))

(defclass temporary-node (node)
    ((order :reader order :initarg :order
            :documentation "Ordering placed on consumers within an environment."))
  (:documentation "Used to record a consumer of a list of nodes."))

(defmethod print-object ((instance assumption) stream)
  (print-unreadable-object (instance stream :identity t)
    (format stream "~:(~S~) ~:[~7,'0D~;~:*~S~]"
            (class-name (class-of instance))
            (name instance)
            (serial-number instance)))
  instance)

(defmethod datum-assumption ((n node) &optional (oldest nil))
  (let ((environment (find-if #'singletonp (label n)
                              :key #'assumptions
                              :from-end oldest)))
    (if environment (car (assumptions environment)))))

(defmethod assumed-datum ((n assumption))
  (consequent (car (consequents n))))

(defmethod add-justification
           ((tms atms) (n assumption) antecedents &optional informant)
  (declare (ignore antecedents informant))
  (error "Attempt to justify an assumption."))

(defmethod add-justification
           ((tms atms) (n node) (antecedents list) &optional informant)
  "Add a justification to a node."
  (let ((justification (make-instance 'justification
                                      :informant informant
                                      :consequent n
                                      :antecedents antecedents)))
    (dolist (node antecedents)
      (push justification (consequents node)))
    (add-justification tms n justification)))

(defmethod add-justification
           ((tms atms) (n node) (j justification) &optional informant)
  "Add a justification to a node, and propagate."
  (declare (ignore informant))
  (push j (justifications n))
  (propagate-label-update j tms))

;(define-modify-macro deletef (item &rest args)
;  (lambda (place item &rest args)
;    (apply #'delete item place args)))

(defmacro deletef (place item &rest args)
  `(setf ,place
     (delete ,item ,place ,@args)))

(defmethod propagate-label-update ((j justification) (tms atms))
  "Propagate the belief states of the antecedents to the consequent."
  (update-label (consequent j)
                tms
                (mapcar #'(lambda (environments)
                            (union-environments tms environments))
                        (cross-product (mapcar #'label (antecedents j))))))

(defmethod update-label ((n node) (tms atms) (label-increment list))
  "Updates label following the addition of a new justification to a node."

  ;; The increment contributed by the new justification is appended to the
  ;; label, after removing the following:
  ;; 1. Nogoods, and environments subsumed by existing label, in contribution.
  ;; 2. Subsumptions within contribution.
  ;; 3. Environments in existing label subsumed by contribution.
  (flet ((subsumed-within-p (new-environment environments)
            (declare (type list environments))
            (some #'(lambda (environment)
                      (subsumesp environment new-environment))
                  environments)))
    (let (filtered-label-increment)
      (setq filtered-label-increment
            (remove-subsumptions
             (delete-if #'(lambda (new-environment)
                            (or (contradictoryp new-environment)
                                (subsumed-within-p new-environment
                                                   (label n))))
                        label-increment)))
      (when filtered-label-increment
        (dolist (environment filtered-label-increment)
          (add-to-agenda n environment))
        (setf (label n)
              (nconc filtered-label-increment
                     (delete-if #'(lambda (environment)
                                    (when (subsumed-within-p environment
                                                       filtered-label-increment)
                                      (deletef (nodes environment) n :test #'eq)
                                      (not nil)))
                                (the list (label n)))))
        (propagate-label-update n tms)))
    n))

(defmethod propagate-label-update ((n node) (tms atms))
  "Propagate label change forward or contradiction backward."
  (if (contradictoryp n)
      (propagate-contradiction n tms)
    (dolist (justification (consequents n))
      (propagate-label-update justification tms))))

(defmethod propagate-contradiction ((n node) (tms atms))
  "Propagate a contradiction backwards."
  (dolist (environment (label n))
    (no-good environment tms))
  (dolist (justification (justifications n))
    (let ((untrue-antecedents (remove-if #'truep
                                         (antecedents justification))))
      (when (singletonp untrue-antecedents)

        ;; All but one antecedent is true, so the other must also be false.
        (setf (contradictoryp (car untrue-antecedents)) (not nil))
        (propagate-contradiction (car untrue-antecedents) tms)))))

(defmethod indexed-size ((environments cons))
  (size (car environments)))

(defmethod no-good ((e environment) (tms atms))
  "Makes environment nogood."
  (unless (assumptions e)
    (error "Contradiction of the empty environment"))

  (record-nogood tms e)

  ;; Set contradictory bit of this and all subsumed environments.
  ;; Remove all of these environments from every node label.
  (do ((entry-point (find (size e) (environment-index tms)
                          :key #'indexed-size
                          :test #'=))
       (environments (environments tms) (cdr environments)))
      ((eq environments entry-point)
       (set-contradictory e))
    (unless (contradictoryp (car environments))
      (when (subsumesp e (car environments))
        (set-contradictory (car environments)))))
  e)

(defmethod record-nogood ((tms atms) (e environment))
  "Adds environment to nogood database."
  (with-slots (nogoods)
              tms
    (deletef nogoods e :test #'subsumesp)
    (cond ((eql (size e) 2)
           (with-slots (assumptions)
                       e
             (record-binary-contradiction (first assumptions)
                                          (second assumptions))))
          ;; Database is a list ordered by increasing size of environment.
          (nogoods (insert e nogoods #'< :key #'size))
          (t (setf nogoods (list e))))))

(defconstant assumption-ordering-predicate #'>)

(defmethod add-contra ((a1 assumption) (a2 assumption))
  (or (insert a1 (contras a2) assumption-ordering-predicate :key #'serial-number)
      (setf (contras a2) (list a1))))

(defmethod record-binary-contradiction ((a1 assumption) (a2 assumption))
  "Record binary contradiction, employing specialized representation."
  (add-contra a1 a2)
  (add-contra a2 a1)
  (not nil))

(defmethod set-contradictory ((e environment))
  "Set contradictory bit of environment and remove from every node label."
  (dolist (node (nodes e))
    (deletef (label node) e :test #'eq))
  (setf (nodes e) nil
        (contradictoryp e) (not nil)))

(defmethod make-environment ((tms atms) (assumptions list))
  (let* ((size (length assumptions))
         (environment (make-instance 'environment
                        :assumptions assumptions
                        :size size))
         entry-point
         entry-point-size
         insertion-point)
    (unless (singletonp assumptions)
      (setf (gethash assumptions (environment-hash-table tms)) environment))
    
    ;; Set of all environments is a list ordered by decreasing size.
    (with-slots (environments environment-index)
        tms
      (cond (environments
             (setq entry-point (or (find size environment-index
                                         :key #'indexed-size
                                         :test #'<=)
                                   environments)
                 entry-point-size (indexed-size entry-point))
             (unless (> size entry-point-size)
               (insert environment entry-point #'>= :key #'size))
             (when (/= size entry-point-size)
               (setq insertion-point (if (> size entry-point-size)
                                         (push environment environments)
                                       (member environment entry-point
                                               :test #'eq)))
               
               ;; Index is organized by increasing size of environment.
               (insert insertion-point environment-index
                       #'<
                       :key #'indexed-size)))
            (t (setf entry-point (list environment)
                 environments entry-point
                 environment-index (list entry-point)))))
    environment))

(defmethod make-assumption ((tms atms) &optional (name nil))
  (let ((assumption (make-instance 'assumption :name name)))
    (setf (serial-number assumption) (incf (last-serial-number assumption))
          (label assumption) (list (make-environment tms (list assumption))))
    assumption))

(defmethod discard-assumption ((tms atms) (n assumption))
  "Garbage assumption."
  ;; Should really be done when environment hash-table is grown.
  (let ((environment (car (label n))))
    (when (or (contradictoryp environment)
              (every #'(lambda (justification)
                         (with-slots (consequent)
                                     justification
                           (or (contradictoryp consequent)
                               (truep consequent))))
                     (consequents n)))
      (with-slots (environments nogoods (index environment-index))
          tms
        (setf index (mapcan #'(lambda (entry-point &aux rest-environments)
                                (setq rest-environments
                                      (member environment entry-point
                                              :test (complement #'subsumesp)))
                                (if (eql (indexed-size rest-environments)
                                         (indexed-size entry-point))
                                    (list rest-environments)))
                      index))
        (deletef environments environment :test #'subsumesp)
        (deletef nogoods environment :test #'subsumesp))
      (dolist (contra (contras n))
        (deletef (contras contra) n :test #'eq))
      n)))

(defmethod truep ((n node))
  (with-slots (label)
              n
    (if label (null (assumptions (car label))))))

(defmethod in-p ((n node) environment)
  (some #'(lambda (e)
            (subsumesp e environment))
        (the list (label n))))

(defmethod subsumesp
    ((e1 environment) (e2 environment) &optional (ordered (not nil)))
  (or (eq e1 e2)
      (subsumesp (assumptions e1) (assumptions e2) ordered)))

(defmethod subsumesp
           ((e environment) (assumptions list) &optional (ordered nil))
  (subsumesp (assumptions e) assumptions ordered))

(defmethod subsumesp
           ((assumptions list) (e environment) &optional (ordered nil))
  (subsumesp assumptions (assumptions e) ordered))

(defmethod
    subsumesp
    ((assumption-set-1 list) (assumption-set-2 list) &optional (ordered nil))
  (unless assumption-set-1
    (return-from subsumesp (not nil)))
  (if ordered

      ;; Optimised for ordered-list representation of assumption sets.
      (do ((list1 assumption-set-1 (rest list1))
           (list2 assumption-set-2 (member (first list1) list2 :test #'eq)))
          ((endp list1) (not (null list2)))
        (when (null list2)
          (return nil)))
    (subsetp assumption-set-1 assumption-set-2 :test #'eq)))

(defmethod size ((assumptions list))
  (length assumptions))

(defmethod add-consumer
           ((tms atms) (antecedents list) consumer &optional (order :after))
  "Add a consumer, attached to a temporary node."
  (add-justification tms
                     (make-instance 'temporary-node :order order)
                     antecedents
                     consumer))

(defmethod consumer ((n temporary-node))
  "Fetch consumer from informant of justification."
  (let ((justification (car (justifications n))))
    (if justification (informant justification))))

(defmethod order ((n node))
  :after)

(defmethod add-to-agenda ((n node) (e environment))
  "Add to partially-ordered list of nodes associated with environment."
  (with-slots (nodes node-added)
      e
    (if nodes
        (insert n nodes #'(lambda (node1 node2)
                            (not (and (eq (order node1) :after)
                                      (eq (order node2) :before)))))
      (setf nodes (list n)))
    (setf node-added (not nil))))

(defmethod execute-consumers ((e environment))
  "Exhaustively execute consumers of nodes in environment."
  
  ;; Executing a consumer may cause a new node, with a consumer, to
  ;; appear in environment.
  (with-slots (nodes node-added contradictory)
      e
    (loop
      (unless node-added
        (return))
      (setf node-added nil)
      (dolist (node nodes)
        (execute-consumer node)
        (when contradictory
          (return-from execute-consumers))
        (when node-added
          (return))))))

(defmethod execute-consumers :after ((e environment))
  "Clean up temporary nodes in environment."
  (with-slots (nodes node-for-deletion)
      e
    (when node-for-deletion
      (deletef nodes nil :key #'justifications :test #'eq)
      (setf node-for-deletion nil))))

(defmethod execute-consumer ((n node))
  nil)

(defmethod execute-consumer ((n temporary-node))
  (let ((consumer (consumer n)))
    (when consumer
      (funcall consumer (car (justifications n))))))

(defmethod mark-for-deletion ((n temporary-node))
  (setf (justifications n) nil)
  (dolist (environment (label n))
    (setf (node-for-deletion environment) (not nil))))

(defmethod reinitialize-instance :before ((j justification) &rest initargs)
  (declare (ignore initargs))
  (mark-for-deletion (consequent j)))

(defun remove-subsumptions (environments)
  "Removes environments that are supersets of others."
  (if environments
      (absorb (car environments)
              (remove-subsumptions (cdr environments))
              #'(lambda (e1 e2)
                  (if (> (size e1) (size e2))
                      (if (subsumesp e2 e1) e2)
                    (if (subsumesp e1 e2) e1))))))

(defun delete-from-environments (node)
  (dolist (environment (label node))
    (deletef (nodes environment) node :test #'eq)))

(defmethod union-environments ((tms atms) (environments list))
  (uniquify-environment tms (if environments
                                (reduce #'union environments :key #'assumptions))))

(defmethod uniquify-environment ((tms atms) (assumptions list)
                                 &optional (dont-create nil) (ordered nil))
  "Returns a unique environment object."
  (when (singletonp assumptions)
    (return-from uniquify-environment (car (label (car assumptions)))))
  (unless ordered
    (setq assumptions
          (sort (copy-list assumptions)
                assumption-ordering-predicate
                :key #'serial-number)))
  (cond ((gethash assumptions (environment-hash-table tms)))
        ((not dont-create)
         (make-environment tms assumptions))))

(defun cross-product (sets)
  (if sets
      (mapcan #'(lambda (element)
                  (mapl #'(lambda (sets)
                            (push element (car sets)))
                        (cross-product (cdr sets))))
              (car sets))
    (make-list 1)))

(defun absorb (item list combiner &key (count 1))
  "Combines item with one or more elements of, or conses onto, list."
  (do ((tail list (cdr tail))
       (occurrences-matched 0)
       new-element)
      ((endp tail)
       (if (zerop occurrences-matched)
           (cons item list)
         list))
    (cond ((= occurrences-matched count)
           (return list))
          ((setf new-element (funcall combiner item (car tail)))
           (setf (car tail) new-element)
           (incf occurrences-matched)))))

(defun insert (item list test &key (key #'identity))
  "Inserts item in list at place satisfied by test, a binary predicate."
  (if (do ((item-key (funcall key item))
           (old-tail nil tail)
           (tail list (cdr tail)))
          ((endp tail)
           (cond (old-tail (setf (cdr old-tail) (list item))
                                               ; Insert at end.
                           (not nil))
                 (t
                    ;; List is empty - cannot insert.
                    nil)))
        (cond ((not (funcall test
                             item-key
                             (funcall key (car tail))))

               ;; Not at insertion point yet.
               )
              (old-tail (setf (cdr old-tail) (cons item tail))
                                               ; Insert.
                        (return (not nil)))
              (t (setf (cdr tail) (cons (car tail) (cdr tail))
                       (car tail) item)
                                               ; Insert at front.
                 (return (not nil)))))
    list))

(defmethod singletonp ((l cons))
  "True for a list of one element."
  (endp (cdr l)))

(defmethod singletonp ((l null))
  "True for a list of one element."
  nil)
;;; -*- Mode: lisp; Syntax: ansi-common-lisp; Base: 10; Package: de.setf.utility.implementation; -*-

(in-package :de.setf.utility.implementation)

;;;  This file part of the 'de.setf.utility' Common Lisp library.
;;;  It defines a method combination to combine arbitrary named methods

;;;  Copyright 2003,2004,2009,2010 [james anderson](mailto:james.anderson@setf.de) All Rights Reserved
;;;  'de.setf.utility' is free software: you can redistribute it and/or modify
;;;  it under the terms of version 3 of the GNU Lesser General Public License as published by
;;;  the Free Software Foundation.
;;;
;;;  'de.setf.utility' is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
;;;  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;;;  See the GNU Lesser General Public License for more details.
;;;
;;;  A copy of the GNU Lesser General Public License should be included with 'de.setf.utility, as `lgpl.txt`.
;;;  If not, see the GNU [site](http://www.gnu.org/licenses/).

;;; 20041010 janderson changed logic of qualifier matching to allow a method to
;;;   match multiple names and play all roles simultaneously
;;; 2005-09-19  janderson  added verbose-p


(modPackage :de.setf.utility
  (:export
   :denominated-progn
   ))

(define-method-combination denominated-progn (&key (operator 'progn)
                                                   ; (predicate nil)
                                                   (qualifiers nil)
                                                   (order :most-specific-first)
                                                   (call-next-method-p t)
                                                   (if-not-applicable nil)
                                                   (verbose-p nil)
                                                   (verbose verbose-p))
                           ((after (:after) :order :most-specific-last)
                            (around (:around) :order :most-specific-first)
                            (before (:before) :order :most-specific-first)
                            (between (:between) :order :most-specific-first)
                            (denominative (:denominative) :order :most-specific-first)
                            (all-methods * :required t :order :most-specific-last))
  (:generic-function function)
  "combine all qualified methods. no unqualified method is permitted. the method
   qualifiers are arbitrary.
   the initial set of applicable methods, as sorted according to the combination's
   :order specification, is grouped by qualifier. the qualifier groups are then
   arranged as specified by the applicable qualifiers for the given function and
   arguments. for a given generic function definition, the qualifiers may be a
   literal list, or it may be a function designator.
   in the latter cases, the function is applied to a list* of the generic function
   and the specializers.
   in order to establish the specializers, if a :denominative method exists, its
   qualifiers are used, otherwise the most specific method is used."
  (ecase if-not-applicable ((nil)) (:error))
  (ecase order (:most-specific-first ) (:most-specific-last ))
  (flet ((eliminate (these from)
           "in case * matches everything, not just those unmatched by others;
            use remove to retain order."
           (dolist (this these) (setf from (remove this from)))
           from))
    (let ((primary (eliminate after
                              (eliminate around
                                         (eliminate before
                                                    (eliminate between all-methods)))))
          (grouped-methods nil)
          (group nil)
          (applicable-qualifiers nil)
          (method-qualifiers nil)
          (qualifier nil)
          (form nil)
          (first-group-p t)
          (initial-called-methods nil))
      (unless primary
        (method-combination-error "no applicable primary methods for ~s."
                                  function))
      (when verbose
        (format t "~%:around: ~s~%:before: ~s~%primary: ~s~%:after: ~s"
                around before primary after))

      ;; collect the qualifier constraints for the given arguments and function
      ;; these are either a literal list, or generated for the specializers
      ;; the denominative method serves the purpoise that, where metaclass management
      ;; does not cause this value to be inherited, it is possible to declare the
      ;; class from which it should be extracted.
      (setf applicable-qualifiers
            (etypecase qualifiers
              (cons
               qualifiers)
              ((or (and symbol (not null)) function)
               (remove-duplicates
                (apply qualifiers function
                       (mapc #'finalize-if-needed 
                             (method-specializers (if denominative
                                                      (first denominative)
                                                    (first (last all-methods))))))
                :from-end t))))
                 
      (when verbose (format *trace-output* "~%~s: ~s -> applicable qualifiers: ~s."
                            function qualifiers applicable-qualifiers))

      ;; group the methods by applicable qualifier, result is least-specific-first
      ;; within arbitrary specializer order
      ;; one could allow  multiples when call-next-method-p was false, but there is
      ;; no clear way to handle multiples which are then superseded.
      ;; allow multiple qualifiers to select for all matching names
      (dolist (method primary)
        (setf method-qualifiers (method-qualifiers method))
        (dolist (qualifier method-qualifiers)
          (if (or (member qualifier applicable-qualifiers) (find t applicable-qualifiers))
              (cond ((setf group (assoc qualifier grouped-methods))
                     (push method (rest group)))
                    (t
                     (push (list qualifier method) grouped-methods)))
            (when if-not-applicable
              (invalid-method-error method "method qualifier not among those permitted: ~s."
                                    applicable-qualifiers)))))
        
        #|more restrictive version allows one qualifier only
          (cond ((= 1 (length method-qualifiers))
               (setf qualifier (first method-qualifiers))
               (if (or (member qualifier applicable-qualifiers) (find t applicable-qualifiers))
                 (cond ((setf group (assoc qualifier grouped-methods))
                        (push method (rest group)))
                       (t
                        (push (list qualifier method) grouped-methods)))
                 (when if-not-applicable
                   (invalid-method-error method "method qualifier not among those permitted: ~s."
                                         applicable-qualifiers))))
              (t
               (invalid-method-error method "method must have exactly one qualifier ~
                                             when call-next-method is allowed.")))|#

      ;; reverse groups if desired to get t groups back in most-specific-last order
      (when (eq order :most-specific-last)
        (setf grouped-methods (reverse grouped-methods)))
      ;; sort the groups by applicable qualifier
      (setf grouped-methods
        (stable-sort grouped-methods #'<
                     :key #'(lambda (group)
                              (or (position (first group) applicable-qualifiers)
                                  (position t applicable-qualifiers)
                                  (error "lost track of position: ~s: ~s."
                                         qualifier applicable-qualifiers)))))
      (when verbose
        (format *trace-output* "~%grouped: ~:w" grouped-methods))
      
      (flet ((call-method-group (method-group &aux call)
               (destructuring-bind (qualifier . methods) method-group
                 ;; reverse them if desired to get the most specific methods within each group last
                 (declare (ignore qualifier))
                 (when (eq order :most-specific-last) (setf methods (reverse methods)))
                 (unless (find (first methods) initial-called-methods)
                   (push (first methods) initial-called-methods)
                   (setf call `(call-method ,(first methods) ,(rest methods)))
                   (if first-group-p
                       (setf first-group-p nil)
                     (when between
                       (setf call `(progn (call-method ,(first between)
                                                       ,(when call-next-method-p (rest between)))
                                          ,call))))
                   call)))
             (call-methods (methods)
               (mapcar #'(lambda (method) `(call-method ,method)) methods)))
        (setf form
              (cond ((rest grouped-methods)
                     ;; if there is more than one group, combine them with the operator.
                     ;; remove groups for which the first method matched more than one
                     ;; qualifier
                     `(,operator ,@(remove nil
                                           (mapcar #'call-method-group grouped-methods))))
                    (grouped-methods
                     (call-method-group (first grouped-methods)))
                    (t
                     (method-combination-error "no method groups: ~s." function))))
        (when before (setf form `(progn ,@(call-methods before) ,form)))
        (when after (setf form `(multiple-value-prog1 ,form ,@(call-methods after)))))

      (when around
        (setf form `(call-method ,(first around)
                                 (,@(rest around)
                                  (make-method ,form)))))

      (when verbose
        (format *trace-output* "~%~s: ~s:~%~:W"
                function `(:around ,around :denominative ,denominative ,all-methods) form))
      
      form)))

#||#

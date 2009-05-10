;;; man-preview.el --- preview nroff man file source

;; Copyright 2008, 2009 Kevin Ryde
;;
;; Author: Kevin Ryde <user42@zip.com.au>
;; Version: 3
;; Keywords: docs
;; URL: http://www.geocities.com/user42_kevin/man-preview/index.html
;; EmacsWiki: NroffMode
;;
;; man-preview.el is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation; either version 3, or (at your option) any later
;; version.
;;
;; man-preview.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
;; Public License for more details.
;;
;; You can get a copy of the GNU General Public License online at
;; <http://www.gnu.org/licenses>.


;;; Commentary:

;; M-x man-preview displays a preview of man nroff source using "man -l".
;; The best feature is that when re-previewing the same file or buffer the
;; existing position in the preview is preserved, so if you've just changed
;; the source a little you should be still quite close to where you were in
;; the preview, to see how the change has come out.
;;
;; M-x man "-l filename" does almost the same as this, but it depends on
;; having a disk copy of a buffer, so it can't work out of tar-mode members
;; etc.

;;; Emacsen:
;;
;; Designed for Emacs 21 and 22.  Works in XEmacs 21.

;;; Install:
;;
;; Put man-preview.el in one of your `load-path' directories, and in your
;; .emacs add
;;
;;     (autoload 'man-preview "man-preview" nil t)
;;
;; to make M-x man-preview available.  You can also bind it to a key, for
;; example f8 in nroff-mode,
;;
;;     (eval-after-load "nroff-mode"
;;       '(define-key nroff-mode-map [f8] 'man-preview))
;;

;;; History:
;;
;; Version 1 - the first version
;; Version 2 - break out the save-display and errorfile bits for clarity
;; Version 3 - xemacs21 switch-to-buffer-other-window only takes one arg

;;; Code:

(require 'man)

;; xemacs incompatibility
(defalias 'man-preview-make-temp-file
  (if (eval-when-compile (fboundp 'make-temp-file))
      'make-temp-file   ;; emacs
    ;; xemacs21
    (autoload 'mm-make-temp-file "mm-util") ;; from gnus
    'mm-make-temp-file))


(defconst man-preview-buffer "*man-preview*"
  "The name of the buffer for `man-preview' output.")

(defconst man-preview-error-buffer "*man-preview-errors*"
  "The name of the buffer for `man-preview' error messages.")

(defvar man-preview-origin nil
  "The name of the input buffer being displayed in `man-preview-buffer'.")


(defmacro man-preview--with-saved-display-position (&rest body)
  "Save window-start and point positions as line/column.
The use of line/column means BODY can erase and rewrite the
buffer contents."

  `(let ((point-column (current-column))
         (point-line   (count-lines (point-min) (line-beginning-position)))
         (window-line  (count-lines (point-min) (window-start))))
     ,@body

     ;; Don't let window-start be the very end of the buffer, since that
     ;; would leave it completely blank.
     (goto-line (1+ window-line))
     (if (= (point) (point-max))
         (forward-line -1))
     (set-window-start (selected-window) (point))
     (goto-line (1+ point-line))
     (move-to-column point-column)))

(defmacro man-preview--with-errorfile (&rest body)
  "Create an `errorfile' for use by the BODY forms.
An `unwind-protect' ensures the file is removed no matter what
BODY does."
  `(let ((errorfile (man-preview-make-temp-file "man-preview-")))
     (unwind-protect
         (progn ,@body)
       (delete-file errorfile))))

;;;###autoload
(defun man-preview ()
  "Preview man page nroff source in the current buffer.
The buffer is put through \"man -l\" and the formatted result
displayed in a buffer.

Errors from man or nroff are shown in a `compilation-mode' buffer
and `next-error' (\\[next-error]) can step through them to see
the offending parts of the source.

------
For reference, the non-ascii situation is roughly as follows.

Traditionally roff input is supposed to be ascii with various
escape directives for further characters and inked accenting to
be rendered on the phototypesetter.  Groff (version 1.18) takes
8-bit input, as latin-1 by default but in principle configurable.
It doesn't, however, have a utf8 input mode, so that should be
avoided (though it can operate on unicode chars internally if
given by escape directives).

man-db 2.5 (October 2007) and up can convert input codings to
latin1 for groff, from a charset given either with an Emacs style
\"coding:\" cookie in the file, or a subdir name like
/usr/share/man/fr.UTF-8/man1, or guessing the content bytes.  The
coding cookie is probably best for `man-preview' (since it just
sends to man's stdin, there's no subdir name for it to follow).

On the output side groff can be asked to produce either latin1 or
utf8 (though quite how well it matches up inked overprinting to
output chars is another matter).

In any case `man-preview' sends per `buffer-file-coding-system',
the same as if it was a file that man ran on.  Output from man is
requested as -Tlatin1 if the input coding is latin-1, or -Tutf8
for anything else and if running in an Emacs which has utf-8."

  (interactive)

  ;; Zap existing `man-preview-error-buffer'.
  ;; Turn off any compilation-mode there so that mode won't attempt to parse
  ;; the contents (until later when they've been variously munged).
  (with-current-buffer (get-buffer-create man-preview-error-buffer)
    (fundamental-mode)
    (setq buffer-read-only nil)
    (erase-buffer))

  (let ((origin-buffer (current-buffer))
        (T-option      "-Tlatin1")
        (T-coding      'iso-8859-1)
        (directory     default-directory))

    ;; Running man with either "-Tlatin1" or "-Tutf8" makes it print
    ;; overstrikes and underscores for bold and italics, which
    ;; `Man-fontify-manpage' (below) crunches into fontification.
    ;;
    ;; It might be that those -T options make man-db 2.5 lose its input
    ;; charset detection ("manconv"), though it seems ok with 2.5.2.
    ;;
    (when (and (not (eq buffer-file-coding-system 'iso-8859-1))
               (memq 'utf-8 (coding-system-list)))
      (setq T-option "-Tutf8")
      (setq T-coding 'utf-8))

    (switch-to-buffer man-preview-buffer)
    (setq buffer-read-only nil)

    ;; default-directory set from the source buffer, so that find-file or
    ;; whatever offers the same default as the source buffer.  This is
    ;; inherited on initial creation of the preview buffer, but has to be
    ;; set explicitly when previewing a new source buffer with a different
    ;; default-directory.
    (setq default-directory directory)

    ;; if previewing a different buffer then erase here so as not to restore
    ;; point+window position into a completely different document
    (if (not (equal man-preview-origin (buffer-name origin-buffer)))
        (erase-buffer))
    (setq man-preview-origin (buffer-name origin-buffer))

    (man-preview--with-errorfile
     (man-preview--with-saved-display-position
      (erase-buffer)

      (with-current-buffer origin-buffer
        (let ((coding-system-for-write buffer-file-coding-system)
              (coding-system-for-read  T-coding))
          (call-process-region (point-min) (point-max) "man"
                               nil ;; don't delete input
                               (list man-preview-buffer errorfile)
                               nil ;; don't redisplay
                               T-option "-l" "-")))

      ;; show errors in a window, but only if there are any
      (save-selected-window
        (with-current-buffer man-preview-error-buffer
          (insert-file-contents errorfile)

          ;; emacs21 compilation regexps don't like "<standard input>" as a
          ;; filename, so mung that (which is easier than adding to the
          ;; patterns)
          (goto-char (point-min))
          (while (re-search-forward "^<standard input>:" nil t)
            (replace-match "standardinput:" t t))

          (if (= (point-min) (point-max))
              (kill-buffer (current-buffer)) ;; no errors

            ;; emacs21 ignores the first two lines of a compilation-mode
            ;; buffer, so add in dummies
            (goto-char (point-min))
            (insert "man-preview\n\n")

            ;; switch to display error buffer
            (let ((existing-window (get-buffer-window (current-buffer))))
              (condition-case nil
                  ;; emacs two args
                  (switch-to-buffer-other-window (current-buffer)
                                                 t) ;; no-record
                (error
                 ;; xemacs one arg
                 (switch-to-buffer-other-window (current-buffer))))
              ;; if newly displaying an error window then shrink to what's
              ;; needed, don't what a half screen if there's only a couple
              ;; of lines
              (if (not existing-window)
                  (shrink-window-if-larger-than-buffer
                   (get-buffer-window (current-buffer)))))
            (compilation-mode))))

      (if (eval-when-compile (fboundp 'Man-mode))
          ;; emacs21 and emacs22
          (progn
            (Man-fontify-manpage)
            (Man-mode))
        ;; xemacs21
        (Manual-nuke-nroff-bs)
        (Manual-mode))))))

(defadvice compilation-find-file (around man-preview activate)
  "Use `man-preview-origin' buffer for its man/nroff errors."
  (if (equal filename "standardinput")
      (setq ad-return-value man-preview-origin)
    ad-do-it))

(provide 'man-preview)

;;; man-preview.el ends here

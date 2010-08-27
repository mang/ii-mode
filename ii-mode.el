(require 'history-ring)

(defvar ii-temp-file     "/tmp/iie.tmp"
  "Temporary file to save messages before catting them into ii input fifos")
(defvar ii-irc-directory "~/irc/"
  "Directory to look for ii files in. end with slash.")
(defvar ii-prompt-marker nil
  "Marker that keeps track of where the prompt starts")
(defvar ii-prompt-text "ii> "
  "Prompt text used")
(defvar ii-inotify-process nil
  "The inotify process")
(defvar ii-channel-data (make-hash-table :test 'equal)
  "Keeps track of channel data")
(defvar ii-mode-hooks nil)

;; standard notifications
(defvar ii-notifications nil
  "Channel files with notifications")

(defvar ii-notify-regexps nil
  "A list of regexps to match incoming text for notification")

(defvar ii-notify-channels nil
  "A list of channels to recieve special notification love. Uses the shortname form \"server/channel\".")

;; fontification
(make-face 'ii-face-nick)
(make-face 'ii-face-date)
(make-face 'ii-face-time)
(make-face 'ii-face-give-voice)
(make-face 'ii-face-take-voice)
(make-face 'ii-face-motd)
(make-face 'ii-face-names)
(make-face 'ii-face-link)
(make-face 'ii-face-mail)
(make-face 'ii-face-shadow)
(make-face 'ii-face-prompt)

(set-face-attribute 'ii-face-nick nil :foreground "chocolate2")
(set-face-attribute 'ii-face-date nil :foreground "#999")
(set-face-attribute 'ii-face-time nil :foreground "#bbb")
(set-face-attribute 'ii-face-give-voice nil :foreground "#0ff")
(set-face-attribute 'ii-face-take-voice nil :foreground "#f0f")
(set-face-attribute 'ii-face-motd nil :foreground "#ff5")
(set-face-attribute 'ii-face-names nil :foreground "#f00")
(set-face-attribute 'ii-face-link nil :foreground "#aaf" :underline 't)
(set-face-attribute 'ii-face-mail nil :foreground "#aaf" :underline 'nil)
(set-face-attribute 'ii-face-shadow nil :foreground "#ccc")
(set-face-attribute 'ii-face-prompt nil :foreground "#0f0")

(defconst ii-font-lock-keywords
  (list '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W\+.*?$" 0 'ii-face-give-voice t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W-.*?$" 0 'ii-face-take-voice t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W-\\W.*?$" 0 'ii-face-motd t)
         '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W=\\W.*?$" 0 'ii-face-names t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W[A-Za-z0-9].*?$" 0 'default t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W-!-.*" 0 'ii-face-shadow t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W\<.+\>.*" 0 'default t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+\\W\<.*?\>" 0 'ii-face-nick t)
        '("^[0-9]+++-[0-9]+-[0-9]+\\W[0-9]+:[0-9]+" 0 'ii-face-time t)
        '("^[0-9]+++-[0-9]+-[0-9]+" 0 'ii-face-date t)
;; todo: fix link regexp
;;        '("\\(\\(http\\|ftp\\)://\\|www\.\\)" 0 'ii-face-link t)
        '("\\(\\.\\|-\\|\\w\\)+@\\(\\.\\|-\\|\\w\\)+\\.\\w\\w+" 0 'ii-face-mail t)
        '("\C-b.*?\C-b" 0 'bold append)
        '("\C-_.*?\C-_" 0 'underline append)
        '("\C-_" 0 'default t)
        '("\C-b" 0 'default t)
        '("^ii>" 0 'ii-face-prompt t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; database/file handling
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-query-file-p (file)
  (string-match (concat "^" ii-irc-directory "[^/]+/[^#&][^/]+/out$") file))

(defun ii-channel-name (name)
  (first (last (split-string (file-name-directory name) "/") 2)))

(defun ii-shortname (long)
  (string-match (concat "^" ii-irc-directory "\\(.*\\)/out$") long)
  (match-string 1 long))

(defun ii-longname (short)
  (concat ii-irc-directory short "/out"))

(defun ii-filesize (file)
  (nth 7 (file-attributes file)))

(defun ii-get-channels ()
  (remove-if (lambda (x) (string= x "")) ; no empty strings
	     (split-string (shell-command-to-string
			    (concat "find " ii-irc-directory " -name out")) "\n")))

(defun ii-get-names ()
  (let ((namesfile (concat (file-name-directory (buffer-file-name)) "names")))
    (when namesfile
      (split-string
       (with-temp-buffer     
	 (insert-file namesfile)
	 (buffer-string))
       "\n" t))))

(defun ii-set-channel-data (channel key value)
  "Sets data for channel"
  (assert (symbolp key))
  (let ((channel-data (or (gethash channel ii-channel-data)
			  (puthash channel (make-hash-table) ii-channel-data))))
    (puthash key value channel-data)))

(defun ii-get-channel-data (channel key)
  "Gets data for channel"
  (let ((channel-data (gethash channel ii-channel-data)))
    (when channel-data
      (gethash key channel-data))))

(defun ii-cache-channel-sizes ()
  "Caches file sizes."
  (dolist (outfile (ii-get-channels))
    (ii-set-channel-data outfile 'size (ii-filesize outfile))))

(defun ii-visit-file-among (list)
  "Takes a list of channel filenames and selects one to visit."
  (let* ((file (ii-longname
		(ido-completing-read 
		 "find: " (mapcar 'ii-shortname list) nil t)))
	 (buffer (some (lambda (x) (when (string= (buffer-file-name x) file) x)) (buffer-list))))
    (if buffer
	(switch-to-buffer buffer)
      (find-file file))))

(defun ii-visit-server-file ()
  "Selects among server channel files"
  (interactive)
  (ii-visit-file-among
   (remove-if-not (lambda (x) (string-match (concat "^" ii-irc-directory "[^/]*/out$") x))
		  (ii-get-channels))))

(defun ii-visit-channel-file ()
  "Selects among all channel files"
  (interactive)
  (ii-visit-file-among (ii-get-channels)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; inotify
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-setup-maybe ()
  "If not already running, start the process and setup buffer sizes."
  (unless (and ii-inotify-process
	       (= (process-exit-status ii-inotify-process) 0))
    (ii-cache-channel-sizes)
    (setf ii-inotify-process
	  (start-process "ii-inotify" nil "inotifywait" "-mr" ii-irc-directory))
    (set-process-filter ii-inotify-process 'ii-handle-inotify)))

(defun ii-handle-inotify (process output)
  "Split inotify output into lines and dispatch on relevant changes"
  (dolist (line (split-string output "\n"))
    (when (string-match "\\(.*\\) CLOSE_WRITE,CLOSE out" line)
      (ii-handle-file-update (concat (match-string 1 line) "out")))))

(defun ii-scroll-to-bottom ()
  (interactive)
  (end-of-buffer)
  (recenter -1))

(defun ii-window-scroll-function (window display-start)
  "Taken from comint mode, originally ERC. <3 Dirty emacs hackarounds"
  (when (and window (window-live-p window))
    (let ((resize-mini-windows nil))
      (save-selected-window
	(select-window window)
	(save-restriction
	  (with-current-buffer (window-buffer window)
	    (widen)
	    (when (< (1- ii-prompt-marker) (point))
	      (save-excursion
		(recenter -1)
		(sit-for 0)))))))))

(defun ii-handle-file-update (file)
  "Called when a channel file is written to."
  (let ((delta      (get-file-delta file))
  	(buffer (get-file-buffer file)))
    (when delta
      (when buffer
	;; Affected file is being changed and visited
	(with-current-buffer buffer	  
	  (let* ((point-past-prompt (< (1- ii-prompt-marker) (point)))
		 (point-from-end (- (point-max) (point)))
		 (inhibit-read-only t))	    
	    (save-excursion
	      (goto-char ii-prompt-marker)
	      (insert-before-markers (propertize delta 'read-only t)))
	    (when point-past-prompt
	      (goto-char (- (point-max) point-from-end))))))
      (when (and (or (not buffer)                      ; either no buffer or
		     (not (get-buffer-window buffer))) ; buffer currently not visible
		 (or (ii-query-file-p file)         ; Either a personal query,
		     (ii-contains-regexp delta)         ; or containing looked-for regexp
		     (ii-special-channel file)))    ; or special channel
	(ii-notify file)))))

(defun get-file-delta (file)
  "Gets the end of the file that has grown."
  (let ((old-size (or (ii-get-channel-data file 'size) 0))
  	(new-size (ii-filesize file)))
    ;; update old value
    (unless (= old-size new-size)
      (ii-set-channel-data file 'size new-size)
      (with-temp-buffer
	(save-excursion
	  (insert-file-contents file nil old-size new-size)
	  (buffer-string))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; mode
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-derived-mode ii-mode fundamental-mode "ii" (ii-mode-init))

(defvar ii-mode-map nil)
(setq ii-mode-map (let ((map (make-sparse-keymap)))
		    (define-key map [remap save-buffer] (lambda () (interactive) (message "nop")))
		    (define-key map [remap end-of-buffer] 'ii-scroll-to-bottom)
		    (define-key map (kbd "C-a") 'ii-beginning-of-line)
		    (define-key map (kbd "TAB") 'completion-at-point)
		    (define-key map (kbd "M-p") 'ii-history-prev)
		    (define-key map (kbd "M-n") 'ii-history-next)
		    (define-key map (kbd "RET") 'ii-send-message)
		    map))

(defun ii-mode-init ()
  (use-local-map ii-mode-map)
  ;; disable autosave
  ;; TODO: disabling "modified; kill anyway?"
  (setf buffer-auto-save-file-name nil)

  ;; rename buffer
  (when (string= (buffer-name) "out")
    (rename-buffer (generate-new-buffer-name (ii-channel-name (buffer-file-name)))))

  ;; local variables.  
  (set (make-local-variable 'ii-prompt-marker) (make-marker))

  ;; coloring
  (set (make-local-variable 'font-lock-defaults)
       '((ii-font-lock-keywords) t))
  (set (make-local-variable 'font-lock-keywords)
       ii-font-lock-keywords)

  ;; init history-ring
  (history-ring-init)

  ;; add hooks
  (add-hook 'window-configuration-change-hook 'ii-clear-notifications nil t)
  (add-hook 'completion-at-point-functions    'ii-completion-at-point nil t)
  (add-hook 'window-scroll-functions          'ii-window-scroll-function nil t)

  ;; insert prompt and make log readonly.
  (goto-char (point-max))
  (set-marker ii-prompt-marker (point))
  (insert ii-prompt-text)
  ;; make it all readonly
  (let ((inhibit-read-only t))
    (put-text-property (point-min) (1+ (point-min)) 'front-sticky t)
    (put-text-property (point-min) (point-max) 'read-only t)
    (put-text-property (1- (point-max)) (point-max) 'rear-nonsticky t))  
  (ii-setup-maybe)
  (goto-char (point-max))
  (ii-scroll-to-bottom)
  (run-hooks ii-mode-hooks))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; completion
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-completion-at-point ()
  (list (save-excursion
	  (search-backward-regexp "\\s-")
	  (forward-char)
	  (point))
	(point)
	(ii-get-names)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; movement
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-beginning-of-line ()
  (interactive)
  (if (> (point) ii-prompt-marker)
      (goto-char (+ ii-prompt-marker (length ii-prompt-text)))
    (move-beginning-of-line nil)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;	     
;; history
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-history-prev ()
  "put the previous message in history-ring at prompt"
  (interactive)
  (history-ring-access 1 (+ ii-prompt-marker (length ii-prompt-text)) (point-max)))
(defun ii-history-next ()
  "put the next message in history-ring at prompt"
  (interactive)
  (history-ring-access -1 (+ ii-prompt-marker (length ii-prompt-text)) (point-max)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; sending messages
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-send-message ()
  "Sends a message to the 'in' file in channel files directory."
  (interactive)
  (let* ((channel-name (buffer-file-name))
	 (fifo-in (concat (file-name-directory channel-name) "in"))
         (msg (ii-clear-and-return-prompt)))
    (unless (file-exists-p fifo-in)
      (error "Invalid channel directory"))
    ;; semi-hack: catting tmpfile asynchronously to fifo to prevent lockups if
    ;; nothing is reading in the other end
    (write-region (concat msg "\n")
                  nil ii-temp-file nil 
                  ;; If VISIT is neither t nor nil nor a string,
                  ;; that means do not display the "Wrote file" message.
                  0)
    (start-process-shell-command
     "ii-sendmessage" nil
     (concat "cat " ii-temp-file " > \"" fifo-in "\""))
    (ii-set-channel-data channel-name 'last-write (current-time))
    (history-ring-add msg)))

(defun ii-clear-and-return-prompt ()
  "Returns the content of prompt while clearing it."
  (let* ((start-pos (+ ii-prompt-marker (length ii-prompt-text)))
	 (text (buffer-substring start-pos (point-max))))
    (delete-region start-pos (point-max))
    text))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; notifications
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ii-notify (file)
  (unless (member file ii-notifications)
    (push file ii-notifications))
  (setf global-mode-string "*ii*"))

(defun ii-contains-regexp (lines)
  (some (lambda (x) (string-match x lines)) ii-notify-regexps))

(defun ii-special-channel (filename)
  (member (ii-shortname filename) ii-notify-channels))

(defun ii-visit-notified-file ()
  "Select among notified files"
  (interactive)
  (when (null ii-notifications) (error "No notifications"))
  (ii-visit-file-among ii-notifications))

(defun ii-clear-notifications ()
  "Removes notification on current buffer if any."
  (when (member (buffer-file-name) ii-notifications)
    (setf ii-notifications
	  (remove (buffer-file-name) ii-notifications)))

  (when (null ii-notifications) 
    (setf global-mode-string "")))

;; leverera

(provide 'ii-mode)
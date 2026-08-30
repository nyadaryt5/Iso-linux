# Run the terminal-first chooser only for the initial local tty1 login.
if [ -t 0 ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ] && \
   [ ! -e "$HOME/.local/state/micro-ubuntu/first-login-complete" ]; then
  /usr/local/bin/micro-first-login
fi

// The same executable also runs as the watcher that puts ⌘Tab back if
// EasyDock ends without doing so; that check comes before anything else.
HotKeyWatchdog.runIfRequested()
EasyDockApp.main()

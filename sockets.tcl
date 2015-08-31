#http://forum.egghelp.org/viewtopic.php?t=13113
# ::sock::Connect <host> <port> ?options? 
# 
#   Create a tcp connection and return the socket id or "" if it 
#   failed. A failure to create the socket most likely means the dns 
#   lookup failed. If you need the actual error message, it will be 
#   stored in $::sock::(error) 
# 
#   Options: 
# 
#      Anything that can be set via ::sock::Set (see below), plus 
#      '-myaddr <vhost>' and '-myport <local port>' 


# ::sock::Listen <port> ?options? 
# 
#   Like Connect, but for creating listening sockets 
#   All options listed under ::sock::Set can be set and are copied to 
#   incoming client connections except "timeout". 
#   The "onDisc" code will be executed if you set a timeout for the 
#   listening socket and let it time out. 
#   You can also specify a vhost using -myaddr <vhost> 

# ::sock::Puts <sock> <data> 
# 
#    Write data to a client socket. 

# ::sock::Close <sock> 
# 
#    Close a socket and clean up its mess 
#   (cancel timers and unset variables used to store options) 


# ::sock::Set <sock> <option> <value> 
# 
#   All options are stored untill the socket is closed. If the 
#   connection is closed by the remote host, they are deleted AFTER 
#   invoking the "onDisc" code. 
#   All options can be changed at any time, but the "onConn" code will 
#   only be   evaluated once for each client socket, so changing it 
#   after the connection has been established has no effect. 
# 
# Options: 
# 
#   mode <line|binary> 
#      affects how data is read/written 
# 
#   timeout <milliseconds> 
#      If the time runs out, the onDisc callback will be executed 
#      before the socket is closed. The timer is killed before 
#      "onConn" is executed, so you'll have to set the timeout again 
#      from within your onConn code if you want it to keep running 
#      after that. 
# 
#   onConn <code> 
#      This code is executed when a connection is established 
#      Appended arguments: the client socket id (and server socket id 
#      if it is a client connecting to a listening socket) 
# 
#   onData <code> 
#      Invoked when data is recieved (set to {} if you don't expect 
#      to recieve any data) 
#      Appended arguments: the socket id and a chunk of data 
# 
#   onDisc <code> 
#      Invoked when an error occurs or the connection is closed by 
#      the remote host or a timeout occurs. 
#      Appended arguments: the socket id and reason/error message. 
# 
#   onAll <code> 
#      A shortcut to set all the other on* callbacks to call the same 
#      proc. The callback name (onConn, onData or onDisc) is appended 
#      as an argument if you provide an empty "code" part, the 
#      commands "onConn", "onData" and "onDisc" will be invoked in 
#      the global namespace. 
# 
# Reserved/custom options: 
# 
#   Options starting with two underscore characters (__) are reserved 
#   for internal use - don't touch them! 
#   Options starting with a dash (-) will be passed to the "socket" 
#   command when creating the socket and then deleted. 
# 
#   Feel free to invent your own options. (As long as they don't 
#   conflict with the reserved ones) This can come in handy if you 
#   need to store som data associated with the socket. 


# ::sock::Get <sock> <option> 
# 
# Retrieve the value of the given option 


# ::sock::Info <sock> <local|remote> <ip/host/port combinations> 
# 
# Retrieve local or remote host, ip and/or port 
# Eg: ::sock::Info $sock local ip:port => 127.0.0.1:6667 
#     ::sock::Info $sock remote host   => wiki.tcl.tk 

package require Tcl 8.2 


namespace eval ::sock { 

   variable "" 

   # default "Connect" options 
   set (connect) { 
      timeout 20000 
      mode line 
      onAll ::sock::Log 
   } 

   # default "Listen" options 
   set (listen) { 
      timeout 0 
      mode line 
      onAll ::sock::Log 
   } 
   lappend (listen) -myaddr [info host] 


   # the "public" procs 
   proc Connect {host port args} { 
      array set "" [concat $::sock::(connect) $args {__type client}] 
      set code [concat [list socket -async] [array get "" -*] [list $host $port]] 
      array unset "" -* 
      if {[catch $code sock]} { 
         set ::sock::(error) $sock 
         return 
      } 
      fconfigure $sock -blocking 0 
      fileevent $sock writable [list ::sock::__onConn $sock] 
      variable $sock 
      array set $sock {} 
      foreach key [lsort -dict [array names ""]] { 
         Set $sock $key $($key) 
      } 
      set sock 
   } 

   proc Listen {port args} { 
      set sid [incr ::sock::(sid)] 
      array set "" [concat $::sock::(listen) $args [list __type server __sid $sid]] 
      set code [list socket -server [list ::sock::__onListen $sid]] 
      eval lappend code [array get "" -*] [list $port] 
      array unset "" -* 
      if {[catch $code sock]} { 
         set ::sock(error) $sock 
         return 
      } 
      set ::sock::($sid) $sock 
      variable $sock 
      array set $sock {} 
      foreach key [lsort -dict [array names ""]] { 
         Set $sock $key $($key) 
      } 
      set sock 
   } 

   proc Puts {sock data} { 
      upvar #0 ::sock::$sock "" 
      if {$(mode)=="binary"} { 
         puts -nonewline $sock $data 
      } { 
         puts $sock $data 
      } 
      flush $sock 
   } 

   proc Close {sock} { 
      upvar #0 ::sock::$sock "" 
      if {[info exists (__after)]} {after cancel $(__after)} 
      if {$(__type)=="server"} {unset ::sock::($(__sid))} 
      close $sock 
      unset "" 
   } 

   proc Set {sock key val} { 
      upvar #0 ::sock::$sock "" 
      if {![array exists ""]} {error "invalid socket \"$sock\""} 
      switch -- $key { 
         "timeout" { 
            if {[info exists (__after)]} { 
               after cancel $(__after) 
               unset (__after) 
            } 
            if {$val>0} { 
               set (__after) [after $val [list ::sock::__onDisc $sock timeout]] 
            } 
         } 
         "mode" { 
            if {$(__type)=="client"} { 
               if {$val=="binary"} { 
                  fconfigure $sock -buffering none -translation binary 
               } { 
                  fconfigure $sock -buffering line -translation auto 
               } 
            } 
         } 
         "onData" { 
            if {$(__type)=="client"} { 
               if {$val=={}} { 
                  fileevent $sock readable {} 
               } { 
                  fileevent $sock readable [list ::sock::__onData $sock] 
               } 
            } 
         } 
         "onAll" { 
            Set $sock onConn [concat $val onConn] 
            Set $sock onData [concat $val onData] 
            Set $sock onDisc [concat $val onDisc] 
         } 
      } 
      set ($key) $val 
   } 
    
   proc Get {sock key} { 
      set ::sock::${sock}($key) 
   } 

   proc Info {sock where what} { 
      set where [string map {local -sockname remote -peername} $where] 
      foreach {ip host port} [fconfigure $sock $where] break 
      string map [list ip $ip host $host port $port] $what 
   } 
    
    
   # "private" procs 
   # (you should never have to invoke these yourself) 
   if {![info exists (sid)]} {set (sid) 0} 
    
   proc __onConn sock { 
      upvar #0 ::sock::$sock "" 
      if {[set err [fconfigure $sock -error]]!=""} { 
         __onDisc $sock $err 
      } { 
         fileevent $sock writable {} 
         __callback $(onConn) $sock 
      } 
   } 

   proc __onListen {sid csock chost cport} { 
      set ssock $::sock::($sid) 
      array set "" [array get ::sock::$ssock] 
      if {[info exists (__after)]} {unset (__after)} 
      set (__type) client 
      set (ssock) $ssock 
      fconfigure $csock -blocking 0 
      variable $csock 
      array set $csock {} 
      foreach key [lsort -dict [array names ""]] { 
         Set $csock $key $($key) 
      } 
      __callback $(onConn) $csock $ssock 
   } 

   proc __onDisc {sock why} { 
      upvar #0 ::sock::$sock "" 
      __callback $(onDisc) $sock $why 
      if {[info exists (__after)]} {after cancel $(__after)} 
      close $sock 
      unset "" 
   } 

   proc __onData sock { 
      upvar #0 ::sock::$sock "" 
      if {$(mode)=="binary"} { 
         set code {[set data [read $sock]]!=""} 
      } { 
         set code {[gets $sock data]>0} 
      } 
      if {[catch {while $code {__callback $(onData) $sock $data}} err]} { 
         __onDisc $sock $err 
      } elseif {[eof $sock]} { 
         __onDisc $sock EOF 
      } elseif {[set err [fconfigure $sock -error]]!=""} { 
         __onDisc $sock $err 
      } 
   } 

   proc __callback {code args} { 
      if {[catch {uplevel #0 [concat $code $args]} err]} { 
         Log "Error executing callback: $err - $::errorInfo" 
      } 
   } 

   if {[llength [info commands putlog]]} { 
      proc Log args {putlog "::sock: [join $args ", "]"} 
   } { 
      proc Log args {puts   "::sock: [join $args ", "]"} 
   } 
} 

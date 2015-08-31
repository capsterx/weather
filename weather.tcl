source scripts/sockets.tcl
source scripts/json.tcl

namespace eval wjson {
  variable apikey ""
  variable conditions [list "\037%{current_observation/display_location/full}\037 \002Conditions\002: %{current_observation/weather} \002Temp\002: %{current_observation/temperature_string} \002Feels Like\002: %{current_observation/feelslike_string}  \002Humidity\002: %{current_observation/relative_humidity} \002Wind\002: %{current_observation/wind_string}  %{current_observation/observation_time} \002Sunrise\002: %{sun_phase/sunrise/hour}:%{sun_phase/sunrise/minute} \002Sunset\002: %{sun_phase/sunset/hour}:%{sun_phase/sunset/minute}" "conditions" "astronomy"]
  variable forecast [list "\002%{forecast/txt_forecast/forecastday<0>/title}\002 %{forecast/txt_forecast/forecastday<0>/fcttext}
\002%{forecast/txt_forecast/forecastday<1>/title}\002 %{forecast/txt_forecast/forecastday<1>/fcttext}
\002%{forecast/txt_forecast/forecastday<2>/title}\002 %{forecast/txt_forecast/forecastday<2>/fcttext}" "forecast"]
#\002%{forcast/txt_forecast/forecastday<3>/title}\002 %{forcast/txt_forecast/forecastday<3>/fcttext}
#\002%{forcast/txt_forecast/forecastday<4>/title}\002 %{forcast/txt_forecast/forecastday<4>/fcttext} 
#\002%{forcast/txt_forecast/forecastday<5>/title}\002 %{forcast/txt_forecast/forecastday<5>/fcttext}
#\002%{forcast/txt_forecast/forecastday<6>/title}\002 %{forcast/txt_forecast/forecastday<6>/fcttext} 
#\002%{forcast/txt_forecast/forecastday<7>/title}\002 %{forcast/txt_forecast/forecastday<7>/fcttext}"
  variable logo ""
  variable textf ""
}

proc wjson::textsplit {text limit} {
  set text [split $text " "]
  set tokens [llength $text]
  set start 0
  set return ""
  while {[llength [lrange $text $start $tokens]] > $limit} {
    incr tokens -1
    if {[llength [lrange $text $start $tokens]] <= $limit} {
      lappend return [join [lrange $text $start $tokens]]
      set start [expr $tokens + 1]
      set tokens [llength $text]
    }
  }
  lappend return [join [lrange $text $start $tokens]]
  return $return
}

proc wjson::msg {chan logo textf text} {
  set text [textsplit $text 50]
  set counter 0
  while {$counter <= [llength $text]} {
    if {[lindex $text $counter] != ""} {
      putlog "PRIVMSG $chan :${logo} ${textf}[string map {\\\" \"} [lindex $text $counter]]"
      putserv "PRIVMSG $chan :${logo} ${textf}[string map {\\\" \"} [lindex $text $counter]]"
    }
    incr counter
  }
}

proc wjson::__callback {code args} {
 if {![string is boolean "$code"]} {
   if {[catch {uplevel #0 [concat $code $args]} err]} {
     putlog "Error $err"
   }
 }
}

proc wjson::handle_url_socket {host uri type sock {arg ""}} { 
   set data [ sock::Get $sock data ]
   #upvar $data_ data

   #putlog "Callback $type"

   switch -- $type { 
      "onConn" { 
         #putlog "CONN: requesting $uri from $host" 
         puts $sock "GET $uri HTTP/1.0\nHost: $host\nConnection: close\n" 
         sock::Set $sock mode binary 
      } 
      "onData" { 
         append data $arg
      } 
      "onDisc" { 
         #putlog "DISC: $arg\n" 
         #puts $data
         set body ""
         set header 0
         foreach line [split $data "\n"] {
           if $header {
             append body $line
             append body "\n"
	   } else {
             set line [string trim $line]
             if [ string equal $line "" ] {
               set header 1
	     }
	   }
	 }
         set body [string trim $body]
         #putlog "body --- $body"
         set json_old [sock::Get $sock json]
         set json_new [json::parse $body]
         set json_data [dict merge $json_old $json_new]
         set next_url [ sock::Get $sock next ]
	 __callback $next_url $json_data
      } 
   }
   sock::Set $sock data $data
}

proc wjson::async_url_fetch {host port url next_url json} {
   set sock [sock::Connect $host $port onAll [list wjson::handle_url_socket $host $url]] 
   sock::Set $sock data ""
   sock::Set $sock json $json
   sock::Set $sock next $next_url
}

proc wjson::parse_conditions {ircdata json} {
  set output_string [dict get $ircdata formatstr]
  #set data [dict get $json [dict get $ircdata "datakey"]]
  set data $json
  set variables [regexp -all -inline {%\{[^\}]*\}} $output_string]
  foreach var $variables {
    set d $data
    foreach elm [split [string range $var 2 end-1] /] {
      if {[string equal [string index $elm end] ">"] && [string equal [string index $elm end-2] "<"]} {
        set index [string range $elm end-1 end-1]
        set elm [string range $elm 0 end-3]
        if [dict exists $d $elm] { 
          set d [dict get $d $elm]
          set d [lindex $d $index]
        } else {
          set d ""
          break
        }
      } else {
        if [dict exists $d $elm] { 
          set d [dict get $d $elm]
        } else {
          set d ""
          break
        }
      }
    }
    set output_string [regsub -all $var $output_string $d]
  }
  foreach m [split $output_string "\n"] {
    msg [dict get $ircdata channel] $wjson::logo ${wjson::textf} $m
  }
}

proc wjson::autocomplete {ircdata json} {
  set results {}
  foreach result [lindex $json 1] {
    if {[dict exists $result type] && [dict get $result type] == "city"} {
      lappend results $result
    }
  }
  if {[llength $results] == 0} {
    msg [dict get $ircdata channel] $wjson::logo ${wjson::textf} "No results found"
    return
  } elseif {[llength $results] > 1} {
    set cities {}
    foreach result $results {
      lappend cities [dict get $result name]
    }
    set str "Found more than one result: '" 
    append str [join $cities "', '"]
    append str "'"
    msg [dict get $ircdata channel] $wjson::logo ${wjson::textf} $str
    return
  } else {
    set loc [dict get [lindex $results 0] l]
    set urlkey [dict get $ircdata "urlkey"]
    async_url_fetch "api.wunderground.com" 80 "/api/$wjson::apikey/$urlkey/$loc.json" [list wjson::parse_conditions $ircdata]
  }
}

proc wjson::urlencode {string} {
  regsub -all {^\{|\}$} $string "" string
  return [subst [regsub -nocase -all {([^a-z0-9\+])} $string {%[format %x [scan "\\&" %c]]}]]
}

proc wjson::query_conditions {ircdata query json} {
  parse_conditions $ircdata $json
}

proc wjson::fetch_url {key keys ircdata query function json} {
  if {[llength $keys] == 0} {
    putlog "last fetch $key"
    async_url_fetch "api.wunderground.com" 80 "/api/$wjson::apikey/$key/q/$query.json" [list $function $ircdata $query] $json
  } else {
    putlog "fetching $key"
    async_url_fetch "api.wunderground.com" 80 "/api/$wjson::apikey/$key/q/$query.json" [list wjson::fetch_urls $keys $ircdata $query $function] $json
  }
}

proc wjson::fetch_urls {keys ircdata query function json} {
  set current_key [lindex $keys 0]
  set keys [lrange $keys 1 end]
  set response [list]
  if {[dict exists $json "response"]} {
   set response [dict get $json "response"]
  }
  putlog "error: [dict exists $response "error"]"
  putlog "results: [dict exists $response "results"]"
  if {[dict exists $response "error"]} {
    async_url_fetch "autocomplete.wunderground.com" 80 "/aq?query=$query" [list wjson::autocomplete $ircdata] [list]
  } elseif {[dict exists $response "results"]} {
    async_url_fetch "autocomplete.wunderground.com" 80 "/aq?query=$query" [list wjson::autocomplete $ircdata] [list]
  } else {
    wjson::fetch_url $current_key $keys $ircdata $query $function $json
  }
}

proc wjson::get_weather {query ircdata} { 
   set query [urlencode $query]
   set keys [dict get $ircdata "keys"]
   set function [dict get $ircdata "function"]
   fetch_urls $keys $ircdata $query $function [list]
} 

proc wjson::egg_get_weather {nick host handle channel text} {
  set fmt [lindex $wjson::conditions 0]
  set keys [lrange $wjson::conditions 1 end]
  get_weather $text [list nick $nick host $host handle $handle channel $channel formatstr $fmt keys $keys function wjson::query_conditions]
}

proc wjson::egg_get_weather_forcast {nick host handle channel text} {
  set fmt [lindex $wjson::forecast 0]
  set keys [lrange $wjson::forecast 1 end]
  get_weather $text [list nick $nick host $host handle $handle channel $channel formatstr $fmt keys $keys function wjson::query_conditions]
}

bind pub -|- .wz wjson::egg_get_weather
bind pub -|- .wzf wjson::egg_get_weather_forcast

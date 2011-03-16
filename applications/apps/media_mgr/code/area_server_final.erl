%% ---
%%  Excerpted from "Programming Erlang",
%%  published by The Pragmatic Bookshelf.
%%  Copyrights apply to this code. It may not be used to create training material, 
%%  courses, books, articles, and the like. Contact us if you are in doubt.
%%  We make no guarantees that this code is fit for any purpose. 
%%  Visit http://www.pragmaticprogrammer.com/titles/jaerlang for more book information.
%%---
-module(area_server_final).  
-export([start/0, area/2]). 

start() -> spawn(fun loop/0).

area(Pid, What) ->
    rpc(Pid, What).

rpc(Pid, Request) ->
    Pid ! {self(), Request},
    receive
	{Pid, Response} ->
	    Response
    end.


loop() ->
    receive
	{From, {rectangle, Width, Ht}} -> 
	    From ! {self(), Width * Ht},
	    loop();
	{From, {circle, R}} -> 
	    From !  {self(), 3.14159 * R * R},
	    loop();
	{From, Other} ->
	    From ! {self(), {error,Other}},
	    loop()
    end.


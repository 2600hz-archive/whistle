%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_net).
-include("rabbit.hrl").

-export([is_ssl/1, ssl_info/1, controlling_process/2, getstat/2,
         async_recv/3, port_command/2, send/2, close/1,
         sockname/1, peername/1, peercert/1]).

%%---------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([socket/0]).

-type(stat_option() ::
	'recv_cnt' | 'recv_max' | 'recv_avg' | 'recv_oct' | 'recv_dvi' |
	'send_cnt' | 'send_max' | 'send_avg' | 'send_oct' | 'send_pend').
-type(ok_val_or_error(A) :: rabbit_types:ok_or_error2(A, any())).
-type(ok_or_any_error() :: rabbit_types:ok_or_error(any())).
-type(socket() :: port() | #ssl_socket{}).

-spec(is_ssl/1 :: (socket()) -> boolean()).
-spec(ssl_info/1 :: (socket())
                    -> 'nossl' | ok_val_or_error(
                                   {atom(), {atom(), atom(), atom()}})).
-spec(controlling_process/2 :: (socket(), pid()) -> ok_or_any_error()).
-spec(getstat/2 ::
        (socket(), [stat_option()])
        -> ok_val_or_error([{stat_option(), integer()}])).
-spec(async_recv/3 ::
        (socket(), integer(), timeout()) -> rabbit_types:ok(any())).
-spec(port_command/2 :: (socket(), iolist()) -> 'true').
-spec(send/2 :: (socket(), binary() | iolist()) -> ok_or_any_error()).
-spec(close/1 :: (socket()) -> ok_or_any_error()).
-spec(sockname/1 ::
        (socket())
        -> ok_val_or_error({inet:ip_address(), rabbit_networking:ip_port()})).
-spec(peername/1 ::
        (socket())
        -> ok_val_or_error({inet:ip_address(), rabbit_networking:ip_port()})).
-spec(peercert/1 ::
        (socket())
        -> 'nossl' | ok_val_or_error(rabbit_ssl:certificate())).

-endif.

%%---------------------------------------------------------------------------

-define(IS_SSL(Sock), is_record(Sock, ssl_socket)).

is_ssl(Sock) -> ?IS_SSL(Sock).

ssl_info(Sock) when ?IS_SSL(Sock) ->
    ssl:connection_info(Sock#ssl_socket.ssl);
ssl_info(_Sock) ->
    nossl.

controlling_process(Sock, Pid) when ?IS_SSL(Sock) ->
    ssl:controlling_process(Sock#ssl_socket.ssl, Pid);
controlling_process(Sock, Pid) when is_port(Sock) ->
    gen_tcp:controlling_process(Sock, Pid).

getstat(Sock, Stats) when ?IS_SSL(Sock) ->
    inet:getstat(Sock#ssl_socket.tcp, Stats);
getstat(Sock, Stats) when is_port(Sock) ->
    inet:getstat(Sock, Stats).

async_recv(Sock, Length, Timeout) when ?IS_SSL(Sock) ->
    Pid = self(),
    Ref = make_ref(),

    spawn(fun () -> Pid ! {inet_async, Sock, Ref,
                           ssl:recv(Sock#ssl_socket.ssl, Length, Timeout)}
          end),

    {ok, Ref};
async_recv(Sock, Length, infinity) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, -1);
async_recv(Sock, Length, Timeout) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, Timeout).

port_command(Sock, Data) when ?IS_SSL(Sock) ->
    case ssl:send(Sock#ssl_socket.ssl, Data) of
        ok              -> self() ! {inet_reply, Sock, ok},
                           true;
        {error, Reason} -> erlang:error(Reason)
    end;
port_command(Sock, Data) when is_port(Sock) ->
    erlang:port_command(Sock, Data).

send(Sock, Data) when ?IS_SSL(Sock) -> ssl:send(Sock#ssl_socket.ssl, Data);
send(Sock, Data) when is_port(Sock) -> gen_tcp:send(Sock, Data).

close(Sock)      when ?IS_SSL(Sock) -> ssl:close(Sock#ssl_socket.ssl);
close(Sock)      when is_port(Sock) -> gen_tcp:close(Sock).

sockname(Sock)   when ?IS_SSL(Sock) -> ssl:sockname(Sock#ssl_socket.ssl);
sockname(Sock)   when is_port(Sock) -> inet:sockname(Sock).

peername(Sock)   when ?IS_SSL(Sock) -> ssl:peername(Sock#ssl_socket.ssl);
peername(Sock)   when is_port(Sock) -> inet:peername(Sock).

peercert(Sock)   when ?IS_SSL(Sock) -> ssl:peercert(Sock#ssl_socket.ssl);
peercert(Sock)   when is_port(Sock) -> nossl.

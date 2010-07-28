%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is the RabbitMQ Erlang Client.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial
%%   Technologies LLC., and Rabbit Technologies Ltd. are Copyright (C)
%%   2007 LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): Ben Hood <0x6e6562@gmail.com>.

%% @private
-module(amqp_main_reader).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([start_link/2, register_framing_channel/3, start_heartbeat/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-record(mr_state, {sock,
                   message = none, %% none | {Type, Channel, Length}
                   framing_channels = amqp_channel_util:new_channel_dict()}).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link(Sock, Framing0Pid) ->
    gen_server:start_link(?MODULE, [Sock, Framing0Pid], []).

register_framing_channel(MainReaderPid, Number, FramingPid) ->
    gen_server:call(MainReaderPid,
                    {register_framing_channel, Number, FramingPid}, infinity).

start_heartbeat(MainReaderPid, Heartbeat) ->
    gen_server:cast(MainReaderPid, {heartbeat, Heartbeat}).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------

init([Sock, Framing0Pid]) ->
    State0 = #mr_state{sock = Sock},
    State1 = internal_register_framing_channel(0, Framing0Pid, State0),
    {ok, _Ref} = rabbit_net:async_recv(Sock, 7, infinity),
    {ok, State1}.

terminate(Reason, #mr_state{sock = Sock}) ->
    Nice = case Reason of
               normal        -> true;
               shutdown      -> true;
               {shutdown, _} -> true;
               _             -> false
           end,
    ok = case Nice of
             true  -> rabbit_net:close(Sock);
             false -> ok
         end.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_call({register_framing_channel, Number, Pid}, _From, State) ->
    {reply, ok, internal_register_framing_channel(Number, Pid, State)}.

handle_cast({heartbeat, Heartbeat}, State = #mr_state{sock = Sock}) ->
    rabbit_heartbeat:start_heartbeat(Sock, Heartbeat),
    {noreply, State}.

handle_info({inet_async, _, _, _} = InetAsync, State) ->
    handle_inet_async(InetAsync, State);
handle_info({'DOWN', _, _, _, _} = Down, State) ->
    handle_down(Down, State);
handle_info(timeout, State) ->
    {stop, connection_timeout, State};
handle_info(socket_closing_timeout, State) ->
    {stop, socket_closing_timeout, State};
handle_info(close, State) ->
    {stop, normal, State}.

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

handle_inet_async({inet_async, Sock, _, Msg},
                  State = #mr_state{sock = Sock,
                                    message = CurMessage}) ->
    {Type, Channel, Length} = case CurMessage of
                                  {T, C, L} -> {T, C, L};
                                  none      -> {none, none, none}
                              end,
    case Msg of
        {ok, <<Payload:Length/binary, ?FRAME_END>>} ->
            case handle_frame(Type, Channel, Payload, State) of
                closed_ok -> {stop, normal, State};
                _         -> {ok, _Ref} =
                                 rabbit_net:async_recv(Sock, 7, infinity),
                             {noreply, State#mr_state{message = none}}
            end;
        {ok, <<NewType:8, NewChannel:16, NewLength:32>>} ->
            {ok, _Ref} = rabbit_net:async_recv(Sock, NewLength + 1, infinity),
            {noreply, State#mr_state{message={NewType, NewChannel, NewLength}}};
        {error, closed} ->
            {stop, socket_closed, State};
        {error, Reason} ->
            {stop, {socket_error, Reason}, State}
    end.

handle_frame(Type, Channel, Payload, State) ->
    case rabbit_reader:analyze_frame(Type, Payload) of
        heartbeat when Channel /= 0 ->
            rabbit_misc:die(frame_error);
        trace when Channel /= 0 ->
            rabbit_misc:die(frame_error);
        %% Match heartbeats and trace frames, but don't do anything with them
        heartbeat ->
            heartbeat;
        trace ->
            trace;
        {method, Method = 'connection.close_ok', none} ->
            pass_frame(Channel, {method, Method}, State),
            closed_ok;
        AnalyzedFrame ->
            pass_frame(Channel, AnalyzedFrame, State)
    end.

pass_frame(Channel, Frame, #mr_state{framing_channels = Channels}) ->
    case amqp_channel_util:resolve_channel_number(Channel, Channels) of
        undefined ->
            ?LOG_INFO("Dropping frame ~p for invalid or closed channel "
                      "number ~p~n", [Frame, Channel]),
            ok;
        FramingPid ->
            rabbit_framing_channel:process(FramingPid, Frame)
    end.

handle_down({'DOWN', _MonitorRef, process, Pid, Info},
            State = #mr_state{framing_channels = Channels}) ->
    case amqp_channel_util:is_channel_pid_registered(Pid, Channels) of
        true ->
            NewChannels =
                amqp_channel_util:unregister_channel_pid(Pid, Channels),
            {noreply, State#mr_state{framing_channels = NewChannels}};
        false ->
            {stop, {unexpected_down, Pid, Info}, State}
    end.

internal_register_framing_channel(
            Number, Pid, State = #mr_state{framing_channels = Channels}) ->
    NewChannels = amqp_channel_util:register_channel(Number, Pid, Channels),
    erlang:monitor(process, Pid),
    State#mr_state{framing_channels = NewChannels}.


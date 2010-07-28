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
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_writer).
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([start/3, start_link/3, shutdown/1, mainloop/1]).
-export([send_command/2, send_command/3, send_command_and_signal_back/3,
         send_command_and_signal_back/4, send_command_and_notify/5]).
-export([internal_send_command/3, internal_send_command/5]).

-import(gen_tcp).

-record(wstate, {sock, channel, frame_max}).

-define(HIBERNATE_AFTER, 5000).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start/3 :: (socket(), channel_number(), non_neg_integer()) -> pid()).
-spec(start_link/3 :: (socket(), channel_number(), non_neg_integer()) -> pid()).
-spec(send_command/2 :: (pid(), amqp_method()) -> 'ok').
-spec(send_command/3 :: (pid(), amqp_method(), content()) -> 'ok').
-spec(send_command_and_signal_back/3 :: (pid(), amqp_method(), pid()) -> 'ok').
-spec(send_command_and_signal_back/4 ::
      (pid(), amqp_method(), content(), pid()) -> 'ok').
-spec(send_command_and_notify/5 ::
      (pid(), pid(), pid(), amqp_method(), content()) -> 'ok').
-spec(internal_send_command/3 ::
      (socket(), channel_number(), amqp_method()) -> 'ok').
-spec(internal_send_command/5 ::
      (socket(), channel_number(), amqp_method(),
       content(), non_neg_integer()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

start(Sock, Channel, FrameMax) ->
    spawn(?MODULE, mainloop, [#wstate{sock = Sock,
                                      channel = Channel,
                                      frame_max = FrameMax}]).

start_link(Sock, Channel, FrameMax) ->
    spawn_link(?MODULE, mainloop, [#wstate{sock = Sock,
                                           channel = Channel,
                                           frame_max = FrameMax}]).

mainloop(State) ->
    receive
        Message -> ?MODULE:mainloop(handle_message(Message, State))
    after ?HIBERNATE_AFTER ->
            erlang:hibernate(?MODULE, mainloop, [State])
    end.

handle_message({send_command, MethodRecord},
               State = #wstate{sock = Sock, channel = Channel}) ->
    ok = internal_send_command_async(Sock, Channel, MethodRecord),
    State;
handle_message({send_command, MethodRecord, Content},
               State = #wstate{sock = Sock,
                               channel = Channel,
                               frame_max = FrameMax}) ->
    ok = internal_send_command_async(Sock, Channel, MethodRecord,
                                     Content, FrameMax),
    State;
handle_message({send_command_and_signal_back, MethodRecord, Parent},
               State = #wstate{sock = Sock, channel = Channel}) ->
    ok = internal_send_command_async(Sock, Channel, MethodRecord),
    Parent ! rabbit_writer_send_command_signal,
    State;
handle_message({send_command_and_signal_back, MethodRecord, Content, Parent},
               State = #wstate{sock = Sock,
                               channel = Channel,
                               frame_max = FrameMax}) ->
    ok = internal_send_command_async(Sock, Channel, MethodRecord,
                                     Content, FrameMax),
    Parent ! rabbit_writer_send_command_signal,
    State;
handle_message({send_command_and_notify, QPid, ChPid, MethodRecord, Content},
               State = #wstate{sock = Sock,
                               channel = Channel,
                               frame_max = FrameMax}) ->
    ok = internal_send_command_async(Sock, Channel, MethodRecord,
                                     Content, FrameMax),
    rabbit_amqqueue:notify_sent(QPid, ChPid),
    State;
handle_message({inet_reply, _, ok}, State) ->
    State;
handle_message({inet_reply, _, Status}, _State) ->
    exit({writer, send_failed, Status});
handle_message(shutdown, _State) ->
    exit(normal);
handle_message(Message, _State) ->
    exit({writer, message_not_understood, Message}).

%---------------------------------------------------------------------------

send_command(W, MethodRecord) ->
    W ! {send_command, MethodRecord},
    ok.

send_command(W, MethodRecord, Content) ->
    W ! {send_command, MethodRecord, Content},
    ok.

send_command_and_signal_back(W, MethodRecord, Parent) ->
    W ! {send_command_and_signal_back, MethodRecord, Parent},
    ok.

send_command_and_signal_back(W, MethodRecord, Content, Parent) ->
    W ! {send_command_and_signal_back, MethodRecord, Content, Parent},
    ok.

send_command_and_notify(W, Q, ChPid, MethodRecord, Content) ->
    W ! {send_command_and_notify, Q, ChPid, MethodRecord, Content},
    ok.

shutdown(W) ->
    W ! shutdown,
    ok.

%---------------------------------------------------------------------------

assemble_frames(Channel, MethodRecord) ->
    ?LOGMESSAGE(out, Channel, MethodRecord, none),
    rabbit_binary_generator:build_simple_method_frame(Channel, MethodRecord).

assemble_frames(Channel, MethodRecord, Content, FrameMax) ->
    ?LOGMESSAGE(out, Channel, MethodRecord, Content),
    MethodName = rabbit_misc:method_record_type(MethodRecord),
    true = rabbit_framing:method_has_content(MethodName), % assertion
    MethodFrame = rabbit_binary_generator:build_simple_method_frame(
                    Channel, MethodRecord),
    ContentFrames = rabbit_binary_generator:build_simple_content_frames(
                      Channel, Content, FrameMax),
    [MethodFrame | ContentFrames].

tcp_send(Sock, Data) ->
    rabbit_misc:throw_on_error(inet_error,
                               fun () -> rabbit_net:send(Sock, Data) end).

internal_send_command(Sock, Channel, MethodRecord) ->
    ok = tcp_send(Sock, assemble_frames(Channel, MethodRecord)).

internal_send_command(Sock, Channel, MethodRecord, Content, FrameMax) ->
    ok = tcp_send(Sock, assemble_frames(Channel, MethodRecord,
                                        Content, FrameMax)).

%% gen_tcp:send/2 does a selective receive of {inet_reply, Sock,
%% Status} to obtain the result. That is bad when it is called from
%% the writer since it requires scanning of the writers possibly quite
%% large message queue.
%%
%% So instead we lift the code from prim_inet:send/2, which is what
%% gen_tcp:send/2 calls, do the first half here and then just process
%% the result code in handle_message/2 as and when it arrives.
%%
%% This means we may end up happily sending data down a closed/broken
%% socket, but that's ok since a) data in the buffers will be lost in
%% any case (so qualitatively we are no worse off than if we used
%% gen_tcp:send/2), and b) we do detect the changed socket status
%% eventually, i.e. when we get round to handling the result code.
%%
%% Also note that the port has bounded buffers and port_command blocks
%% when these are full. So the fact that we process the result
%% asynchronously does not impact flow control.
internal_send_command_async(Sock, Channel, MethodRecord) ->
    true = port_cmd(Sock, assemble_frames(Channel, MethodRecord)),
    ok.

internal_send_command_async(Sock, Channel, MethodRecord, Content, FrameMax) ->
    true = port_cmd(Sock, assemble_frames(Channel, MethodRecord,
                                              Content, FrameMax)),
    ok.

port_cmd(Sock, Data) ->
    try rabbit_net:port_command(Sock, Data)
    catch error:Error -> exit({writer, send_failed, Error})
    end.

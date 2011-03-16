%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, James Aimonetti
%%% @doc
%%% Account module
%%%
%%% Handle client requests for account documents
%%%
%%% @end
%%% Created : 10 Feb 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(evtsub).

-behaviour(gen_server).

%% API
-export([start_link/0, get_subscriber_pid/1, add_subscriber_pid/2, rm_subscriber_pid/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(logger, [format_log/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).
-define(MAX_STREAM_EVENTS, 10). % how many events to store for a stream at a time
-define(MAX_AMQP_RETRIES, 5). % how many times to retry connecting to the host before just going down
-define(EMPTY_STREAMS, []).
-define(EMPTY_EVENTS, {struct, []}).

%% {SessionId, PidToQueueHandlingProc}
-type evtsub_subscriber() :: tuple( binary(), pid()).
-type evtsub_subscriber_list() :: list(evtsub_subscriber()) | [].

%% {Stream, PidToStreamProc}
-type subscriber_stream() :: tuple(binary(), pid()).
-type subscriber_stream_list() :: list(subscriber_stream()) | [].

-record(state, {
	  subscriber_list = [] :: evtsub_subscriber_list()
	 ,subscriptions_allowed = [<<"directory.auth_req">>, <<"dialplan.route_req">>
				       ,<<"events.*">>, <<"cdr.*">>] :: list(binary())
	 }).
-record(stream_state, {
	  max_events = ?MAX_STREAM_EVENTS :: integer()
	  ,stream = <<>> :: binary()
	  ,amqp_queue = <<>> :: binary() | tuple(error, _)
	  ,amqp_host = <<>> :: binary()
	  ,current_events = [] :: json_objects() %% list of JObj
	  ,overflow_events = [] :: json_objects()
	  ,event_count = 0 :: integer()
	  ,overflow_count = 0 :: integer()
	  ,is_consuming = true :: boolean()
	 }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(get_subscriber_pid/1 :: (SessionID :: binary()) -> tuple(ok, pid()) | tuple(error, undefined)).
get_subscriber_pid(SessionID) ->
    gen_server:call(?SERVER, {get_subscriber_pid, SessionID}).

add_subscriber_pid(SessionID, Pid) ->
    gen_server:cast(?SERVER, {add_subscriber_pid, SessionID, Pid}).

rm_subscriber_pid(SessionID) ->
    gen_server:cast(?SERVER, {rm_subscriber_pid, SessionID}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init/1 :: (_) -> tuple(ok, #state{})).
init([]) ->
    bind_to_crossbar(),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({get_subscriber_pid, SessionId}, _, #state{subscriber_list=Ss}=State) ->
    Resp = case lists:keyfind(SessionId, 1, Ss) of
	       false -> {error, undefined};
	       {_, Pid} when is_pid(Pid) -> {ok, Pid}
	   end,
    {reply, Resp, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({add_subscriber_pid, SessionID, Pid}, #state{subscriber_list=Ss}=State) ->
    case lists:keyfind(SessionID, 1, Ss) of
	false ->
	    link(Pid),
	    {noreply, State#state{subscriber_list=[{SessionID, Pid} | Ss]}};
	_ ->
	    {noreply, State}
    end;
handle_cast({rm_subscriber_pid, SessionID}, #state{subscriber_list=Ss}=State) ->
    case lists:keyfind(SessionID, 1, Ss) of
	{_, Pid} ->
	    case erlang:is_process_alive(Pid) of
		true ->
		    unlink(Pid),
		    Pid ! shutdown;
	       false ->
		    ok
	    end,
	    {noreply, State#state{subscriber_list=lists:keydelete(SessionID, 1, Ss)}};
	false ->
	    {noreply, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} | 
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.evtsub">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.evtsub">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.evtsub">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
		  crossbar_util:binding_heartbeat(Pid),
		  Context1 = validate(Params, Context),
		  Pid ! {binding_result, true, [RD, Context1, Params]}
	 end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.get.evtsub">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
		  Pid ! {binding_result, true, [RD, Context, Params]}
    	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.evtsub">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
		  Pid ! {binding_result, true, [RD, Context, Params]}
     	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.evtsub">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
		  Pid ! {binding_result, true, [RD, Context, Params]}
    	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.evtsub">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Pid ! {binding_result, true, [RD, Context, Params]}
    	  end),
    {noreply, State};

handle_info({binding_fired, Pid, _Route, Payload}, State) ->
    %%format_log(info, "ACCOUNTS(~p): unhandled binding: ~p~n", [self(), Route]),
    Pid ! {binding_result, true, Payload},
    {noreply, State};

handle_info(_Info, State) ->
    format_log(info, "EVTSUB(~p): unhandled info ~p~n", [self(), _Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function binds this server to the crossbar bindings server,
%% for the keys we need to consume.
%% @end
%%--------------------------------------------------------------------
-spec(bind_to_crossbar/0 :: () ->  ok | tuple(error, exists)).
bind_to_crossbar() ->
    crossbar_bindings:bind(<<"v1_resource.allowed_methods.evtsub">>),
    crossbar_bindings:bind(<<"v1_resource.resource_exists.evtsub">>),
    crossbar_bindings:bind(<<"v1_resource.validate.evtsub">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.evtsub">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Paths contains the tokenized portions of the URI after the module
%% /account/{AID}/evtsub => Paths == []
%% /account/{AID}/evtsub/{CallID} => Paths = [<<CallID>>]
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec(allowed_methods/1 :: (Paths :: list()) -> tuple(boolean(), http_methods())).
allowed_methods([]) ->
    {true, ['GET', 'PUT', 'DELETE']};
allowed_methods([_CallID]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods(_Paths) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Paths contains the tokenized portions of the URI after the module
%% /account/{AID}/evtsub => Paths == []
%% /account/{AID}/evtsub/{CallID} => Paths = [<<CallID>>]
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec(resource_exists/1 :: (Paths :: list()) -> tuple(boolean(), [])).
resource_exists([]) ->
    {true, []};
resource_exists([_CallID]) ->
    {true, []};
resource_exists(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (Params :: list(), Context :: #cb_context{}) -> #cb_context{}).
validate([], #cb_context{req_verb = <<"get">>, session=Session}=Context) ->
    %% get list of subscriptions and events, if any
    case ?MODULE:get_subscriber_pid(Session#session.'_id') of
	{ok, SubPid} ->
	    Streams = get_streams(SubPid),
	    Events = flush_events(SubPid),
	    crossbar_util:response({struct, [{<<"streams">>, Streams}, {<<"events">>, Events}]}, Context);
	{error, undefined} ->
	    start_subscription_handler(Session),
	    crossbar_util:response({struct, [{<<"streams">>, []}, {<<"events">>, ?EMPTY_EVENTS}]}, Context)
    end;
validate([], #cb_context{req_verb = <<"put">>, session=Session, req_data=Data}=Context) ->
    %% create a queue bound to the event stream
    SubPid = case ?MODULE:get_subscriber_pid(Session#session.'_id') of
		 {ok, P} -> P;
		 {error, undefined} -> start_subscription_handler(Session)
	     end,

    Stream = whapps_json:get_value(<<"stream">>, Data),
    case Stream of
	undefined ->
	    crossbar_util:response_faulty_request(Context);
	_ ->
	    MaxEvents = constrain_max_events(whapps_json:get_value(<<"max-events">>, Data, ?MAX_STREAM_EVENTS)),
	    add_stream(SubPid, Stream, MaxEvents),
	    Streams = get_streams(SubPid),
	    crossbar_util:response({struct, [{<<"streams">>, Streams}]}
				   ,Context#cb_context{resp_headers=[
								     {"Location", Stream}
								     | Context#cb_context.resp_headers
								    ]})
    end;
validate([], #cb_context{req_verb = <<"delete">>, session=Session, req_data=Data}=Context) ->
    {Ss, Es} = case ?MODULE:get_subscriber_pid(Session#session.'_id') of
		   {ok, SubPid} ->
		       Flush = whapps_json:get_value(<<"flush">>, Data, false),
		       rm_stream(SubPid, all, whistle_util:to_boolean(Flush));
		   {error, undefined} ->
		       start_subscription_handler(Session),
		       {[], ?EMPTY_EVENTS}
	       end,
    crossbar_util:response({struct, [{<<"streams">>, Ss}, {<<"events">>, Es}]}, Context);
validate([Stream], #cb_context{req_verb = <<"get">>, session=Session}=Context) ->
    %% get list of events, if any
    case ?MODULE:get_subscriber_pid(Session#session.'_id') of
	{ok, SubPid} ->
	    Events = flush_events(SubPid, Stream),
	    crossbar_util:response({struct, [{<<"events">>, Events}]}, Context);
	{error, undefined} ->
	    start_subscription_handler(Session),
	    crossbar_util:response({struct, [{<<"events">>, ?EMPTY_EVENTS}]}, Context)
    end;
validate([Stream], #cb_context{req_verb = <<"post">>, session=Session, req_data=Data}=Context) ->
    %% create a queue bound to the event stream
    SubPid = case ?MODULE:get_subscriber_pid(Session#session.'_id') of
		 {ok, P} -> P;
		 {error, undefined} -> start_subscription_handler(Session)
	     end,

    MaxEvents = constrain_max_events(whapps_json:get_value(<<"max-events">>, Data, ?MAX_STREAM_EVENTS)),

    format_log(info, "Attempting to update ~p(~p) to ~p~n", [Stream, MaxEvents, SubPid]),
    update_stream(SubPid, Stream, MaxEvents),
    Streams = get_streams(SubPid),
    crossbar_util:response({struct, [{<<"streams">>, Streams}]}, Context);
validate([Stream], #cb_context{req_verb = <<"delete">>, session=Session, req_data=Data}=Context) ->
    %% remove stream from subscriber
    {Ss, Es} = case ?MODULE:get_subscriber_pid(Session#session.'_id') of
		   {ok, SubPid} ->
		       Flush = whapps_json:get_value(<<"flush">>, Data, false),
		       rm_stream(SubPid, Stream, whistle_util:to_boolean(Flush));
		   {error, undefined} ->
		       start_subscription_handler(Session),
		       {[], []}
	       end,
    crossbar_util:response({struct, [{<<"streams">>, Ss}, {<<"events">>, Es}]}, Context);
validate(Params, #cb_context{req_verb=Verb, req_nouns=Nouns, req_data=D}=Context) ->
    format_log(info, "EvtSub.validate: P: ~p~nV: ~s Ns: ~p~nData: ~p~nContext: ~p~n", [Params, Verb, Nouns, D, Context]),
    crossbar_util:response_faulty_request(Context).

%% Subscriber-related functions
%% Per-session process and helper functions to add/rm streams and get events associated with the streams

%% flush events from the subscriber pid; if stream is specified, only from that one; otherwise from all
-spec(flush_events/1 :: (SubPid :: pid()) -> json_objects()).
flush_events(SubPid) ->
    flush_events(SubPid, all).

-spec(flush_events/2 :: (SubPid :: pid(), Stream :: all | binary()) -> json_objects()).
flush_events(SubPid, Stream) ->
    SubPid ! {get_events, self(), Stream},
    receive
	{events, Evts} -> Evts
    end.

%% get all streams subscriber is listening to
-spec(get_streams/1 :: (SubPid :: pid()) -> list(binary())).
get_streams(SubPid) ->
    SubPid ! {get_streams, self()},
    receive
	{streams, []} -> ?EMPTY_STREAMS;
	{streams, Streams} -> Streams
    end.

-spec(add_stream/3 :: (SubPid :: pid(), Stream :: undefined | binary(), MaxEvents :: integer()) -> ok | error).
add_stream(_, undefined, _) -> error;
add_stream(SubPid, Stream, MaxEvents) ->
    SubPid ! {add_stream, Stream, MaxEvents},
    ok.

update_stream(SubPid, Stream, MaxEvents) ->
    SubPid ! {update_stream, Stream, MaxEvents},
    ok.

-spec(rm_stream/3 :: (SubPid :: pid(), Stream :: binary() | 'all', Flush :: boolean()) -> tuple(list(binary()) | [], json_objects() | ?EMPTY_EVENTS)).
rm_stream(SubPid, Stream, true) ->
    Evts = flush_events(SubPid, Stream),
    {Streams, _} = rm_stream(SubPid, Stream, false),
    {Streams, Evts};
rm_stream(SubPid, Stream, false) ->
    SubPid ! {rm_stream, self(), Stream},
    receive
	{streams, []} ->
	    {?EMPTY_STREAMS, ?EMPTY_EVENTS};
	{streams, Streams} ->
	    {Streams, ?EMPTY_EVENTS}
    end.

%% start the loop for a subscriber
-spec(start_subscription_handler/1 :: (Session :: #session{}) -> pid()).
start_subscription_handler(Session) ->
    Pid = spawn(fun() -> process_flag(trap_exit, true), subscriber_loop([]) end),
    ?MODULE:add_subscriber_pid(Session#session.'_id', Pid),
    format_log(info, "Subscriber(~p): Started for ~p~n", [Pid, Session#session.'_id']),
    Pid.

-spec(subscriber_loop/1 :: (Streams :: subscriber_stream_list()) -> no_return()).
subscriber_loop(Streams) ->
    receive
	{add_stream, Stream, MaxEvents}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    case lists:keyfind(Stream, 1, Streams) of
		{_, _Pid} ->
		    format_log(info, "Subscriber(~p): Already have stream ~p~n", [self(), Stream]),
		    subscriber_loop(Streams);
		false ->
		    Pid = spawn(fun() -> stream_loop(start_amqp(#stream_state{max_events=MaxEvents, stream=Stream})) end),
		    link(Pid),
		    format_log(info, "Subscriber(~p): Adding stream ~p: ~p~n", [self(), Stream, Pid]),
		    subscriber_loop([ {Stream, Pid} | Streams])
	    end;
	{update_stream, Stream, MaxEvents}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    case lists:keyfind(Stream, 1, Streams) of
		{_, SPid} ->
		    SPid ! {set_max_events, MaxEvents};
		false -> ok
	    end,
	    subscriber_loop(Streams);
	{rm_stream, RespPid, all}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    lists:foreach(fun({_, SPid}) -> SPid ! shutdown end, Streams),
	    RespPid ! {streams, []},
	    subscriber_loop([]);
	{rm_stream, RespPid, Stream}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    case lists:keyfind(Stream, 1, Streams) of
		{_, Pid} ->
		    unlink(Pid),
		    Pid ! shutdown,
		    Streams1 = lists:keydelete(Stream, 1, Streams),
		    RespPid ! {streams, Streams1},
		    subscriber_loop(Streams1);
		false ->
		    RespPid ! {streams, Streams},
		    subscriber_loop(Streams)
	    end;
	{get_events, RespPid, ReqStream}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    Evts = lists:foldl(fun({Stream, Pid}, Acc) when ReqStream =:= all orelse ReqStream =:= Stream ->
				       Pid ! {get_events, self()},
				       receive
					   {events, []} ->
					       [ {Stream, []} | Acc];
					   {events, Events} ->
					       [ {Stream, Events} | Acc ]
				       after 500 -> Acc
				       end;
				  (_, Acc) -> Acc
			       end, [], Streams),
	    RespPid ! {events, {struct, Evts}},
	    subscriber_loop(Streams);
	{get_streams, RespPid}=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p: ~p~n", [self(), _Recv, Streams]),
	    RespPid ! {streams, [ S || {S, SPid} <- Streams,
				       erlang:is_process_alive(SPid)
				]},
	    subscriber_loop(Streams);
	shutdown=_Recv ->
	    format_log(info, "Subscriber(~p): recv ~p~n", [self(), _Recv]),
	    lists:foreach(fun({_, Pid}) -> Pid ! shutdown end, Streams),
	    ok;
	{'EXIT', StreamPid, _Reason} ->
	    case lists:keyfind(StreamPid, 2, Streams) of
		false -> subscriber_loop(Streams);
		{Stream, _} ->
		    format_log(error, "Subscriber(~p): ~p(~p) went down: ~p~n", [self(), Stream, StreamPid, _Reason]),
		    subscriber_loop(lists:keydelete(Stream,1, Streams))
	    end;
	_Other ->
	    format_log(info, "Subscriber(~p): Recv ~p~n", [self(), _Other]),
	    subscriber_loop(Streams)
    after 5000 ->
	    subscriber_loop([ {S, SPid} || {S, SPid} <- Streams,
					   erlang:is_process_alive(SPid)
			    ])
    end.

%% Stream-related functions and loop
%% A stream belongs to a subscriber
-spec(stream_loop/1 :: (StreamState :: #stream_state{}) -> no_return()).
stream_loop(#stream_state{amqp_queue = <<>>}=StreamState) ->
    stream_amqp_loop(start_amqp(StreamState), 0);
stream_loop(#stream_state{amqp_queue = {error, _}}=StreamState) ->
    stream_amqp_loop(start_amqp(StreamState), 0);
stream_loop(#stream_state{current_events = [], overflow_events = OE, overflow_count = OC}=StreamState) when OC > 0 ->
    MaxEvents = StreamState#stream_state.max_events,
    case OC > MaxEvents of
	true ->
	    {Curr, Over} = lists:split(MaxEvents, OE),
	    stream_loop(StreamState#stream_state{current_events=Curr, event_count=MaxEvents, overflow_events=Over, overflow_count=(OC - MaxEvents)});
	false ->
	    stream_loop(StreamState#stream_state{current_events=OE, event_count=OC, overflow_events=[], overflow_count=0})
    end;
stream_loop(#stream_state{amqp_queue=Q, amqp_host=H} = StreamState) ->
try
    receive
	{_, #amqp_msg{payload = Payload}} ->
	    {struct, Prop} = JObj = mochijson2:decode(Payload),
	    true = validate_amqp(props:get_value(<<"Event-Category">>, Prop), props:get_value(<<"Event-Name">>, Prop), Prop),

	    Events = StreamState#stream_state.current_events,
	    EventCount = StreamState#stream_state.event_count,
	    OverflowEvents = StreamState#stream_state.overflow_events,
	    OverflowCount = StreamState#stream_state.overflow_count,
	    MaxEvents = StreamState#stream_state.max_events,

	    format_log(info, "Stream(~p): EC: ~p OC: ~p ME: ~p~n", [self(), EventCount, OverflowCount, MaxEvents]),

	    case EventCount of
		MaxEvents ->
		    stream_loop(StreamState#stream_state{overflow_events = [ JObj | OverflowEvents], overflow_count = OverflowCount + 1});
		X when X =:= (MaxEvents-1) ->
		    stop_consuming(H, Q),
		    stream_loop(StreamState#stream_state{current_events = [ JObj | Events], event_count = EventCount + 1, is_consuming = false});
		Y when Y < MaxEvents ->
		    stream_loop(StreamState#stream_state{current_events = [ JObj | Events], event_count = EventCount + 1})
	    end;
	{amqp_host_down, _} ->
	    stream_loop(StreamState#stream_state{amqp_queue = <<>>, amqp_host = <<>>});
	{get_events, RespPid} ->
	    RespPid ! {events, StreamState#stream_state.current_events},
	    case StreamState#stream_state.is_consuming of
		true -> stream_loop(StreamState#stream_state{current_events = [], event_count = 0});
		false ->
		    start_consuming(H, Q),
		    stream_loop(StreamState#stream_state{current_events = [], event_count = 0, is_consuming = true})
	    end;
	{set_max_events, MaxEvt} ->
	    stream_loop(StreamState#stream_state{max_events=MaxEvt});
	shutdown ->
	    stop_consuming(H, Q),
	    amqp_util:delete_queue(H, Q),
	    ok;
	_Other ->
	    format_log(error, "Stream(~p): Unknown msg: ~p~n", [self(), _Other]),
	    stream_loop(StreamState)
    end
catch
  A:B ->
	format_log(error, "Stream(~p).catch: ~p: ~p~n~p~n", [self(), A, B, erlang:get_stacktrace()]),
	stream_loop(StreamState)
end.

%% loop a couple times to try to re-establish conn to amqp
stream_amqp_loop(#stream_state{amqp_queue={error, _}, stream=Stream}, ?MAX_AMQP_RETRIES) ->
    format_log(error, "Stream ~s going down after too many amqp restart attempts~n", [Stream]);
stream_amqp_loop(#stream_state{amqp_queue={error, _}}=StreamState, N) ->
    timer:sleep(500 * N), % wait progressively longer to reconnect
    stream_amqp_loop(start_amqp(StreamState), N+1);
stream_amqp_loop(#stream_state{amqp_queue=Q}=StreamState, _) when is_binary(Q) ->
    stream_loop(StreamState).

-spec(start_amqp/1 :: (StreamState :: #stream_state{}) -> #stream_state{}).
start_amqp(#stream_state{stream=Stream, amqp_queue=OldQ, amqp_host=OldH}=StreamState) ->
    spawn(fun() -> amqp_util:delete_queue(OldH, OldQ) end),
    H = whapps_controller:get_amqp_host(),
    Q = amqp_util:new_queue(H, <<>>, [{auto_delete, false}]),
    bind_to_exchange(Stream, H, Q),
    amqp_util:basic_consume(H, Q),
    StreamState#stream_state{amqp_queue=Q, amqp_host=H, is_consuming=true}.

start_consuming(H, Q) ->
    amqp_util:basic_consume(H, Q).

stop_consuming(H, Q) ->
    amqp_util:basic_cancel(H, Q).

bind_to_exchange(<<"directory.auth_req">>, H, Q) ->
    amqp_util:bind_q_to_callmgr(H, Q, ?KEY_AUTH_REQ);
bind_to_exchange(<<"dialplan.route_req">>, H, Q) ->
    amqp_util:bind_q_to_callmgr(H, Q, ?KEY_ROUTE_REQ);
bind_to_exchange(<<"events.", CallID/binary>>, H, Q) ->
    amqp_util:bind_q_to_callevt(H, Q, CallID, events);
bind_to_exchange(<<"cdr.", CallID/binary>>, H, Q) ->
    amqp_util:bind_q_to_callevt(H, Q, CallID, cdr).

-spec(validate_amqp/3 :: (Category :: binary(), Name :: binary(), Prop :: json_object()) -> boolean()).
validate_amqp(<<"directory">>, <<"auth_req">>, Prop) ->
    whistle_api:auth_req_v(Prop);
validate_amqp(<<"dialplan">>, <<"route_req">>, Prop) ->
    whistle_api:route_req_v(Prop);
validate_amqp(<<"call_event">>, _, Prop) ->
    whistle_api:call_event_v(Prop);
validate_amqp(_Cat, _Name, _Prop) ->
    false.

-spec(constrain_max_events/1 :: (MaxEvents :: binary() | integer()) -> integer()).
constrain_max_events(X) when not is_integer(X) ->
    constrain_max_events(whistle_util:to_integer(X));
constrain_max_events(Max) when Max > ?MAX_STREAM_EVENTS -> ?MAX_STREAM_EVENTS;
constrain_max_events(Min) when Min < 1 -> 1;
constrain_max_events(Okay) -> whistle_util:to_integer(Okay).

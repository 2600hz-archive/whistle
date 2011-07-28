%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% VMBoxes module
%%%
%%%
%%% Handle client requests for vmbox documents
%%%
%%% @end
%%% Created : 05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cb_vmboxes).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).

-define(VIEW_FILE, <<"views/vmboxes.json">>).
-define(CB_LIST, <<"vmboxes/crossbar_listing">>).

-define(MESSAGES_RESOURCE, <<"messages">>).
-define(MESSAGE_AUDIO_EXT, <<".mp3">>).
-define(BIN_DATA, <<"raw">>).
-define(MEDIA_MIME_TYPES, [ "application/octet-stream"]).

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
init(_) ->
    {ok, ok, 0}.

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
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

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
handle_cast(_Msg, State) ->
    {noreply, State}.

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
handle_info({binding_fired, Pid, <<"v1_resource.content_types_provided.vmboxes">>, {RD, Context, Params}}, State) ->
    spawn(fun() ->
		  Context1 = content_types_provided(Params, Context),
		  Pid ! {binding_result, true, {RD, Context1, Params}}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.vmboxes">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.vmboxes">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:put_reqid(Context),
		  crossbar_util:binding_heartbeat(Pid),
		  Context1 = validate(Params, Context),
		  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.get.vmboxes">>, [RD, Context | Params]}, State) ->
    case Params of
	[_, ?MESSAGES_RESOURCE, AttachmentId, ?BIN_DATA] ->
	    spawn(fun() ->
                          crossbar_util:put_reqid(Context),
			  Name = attachment_name(AttachmentId),
			  Context1 = Context#cb_context{resp_headers = [
				      {<<"Content-Type">> ,wh_json:get_value(<<"content-type">>, Context#cb_context.doc)},
				      {<<"Content-Disposition">>, << "Content-Disposition: attachment; filename=", Name/binary>>},
				      {<<"Content-Length">> ,whistle_util:to_binary(binary:referenced_byte_size(Context#cb_context.resp_data))}
				      | Context#cb_context.resp_headers]},

			  Pid ! {binding_result, true, [RD, Context1, Params]}

		  end);
	_ ->
	    spawn(fun() ->
			  Pid ! {binding_result, true, [RD, Context, Params]}
		  end)
    end,
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:put_reqid(Context),
		  Context1 = crossbar_doc:save(Context),
		  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.vmboxes">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:put_reqid(Context),
		  Context1 = crossbar_doc:save(Context),
		  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.vmboxes">>, [RD, Context | Params]}, State) ->
    case Params of
	[_, ?MESSAGES_RESOURCE, _] ->
	    spawn(fun() ->
                          crossbar_util:put_reqid(Context),
			  Context1 = crossbar_doc:save(Context),
			  Pid ! {binding_result, true, [RD, Context1, Params]}
		  end);
	_ ->
	    spawn(fun() ->
                          crossbar_util:put_reqid(Context),
			  Context1 = crossbar_doc:delete(Context),
			  Pid ! {binding_result, true, [RD, Context1, Params]}
		  end)
    end,
    {noreply, State};

handle_info({binding_fired, Pid, <<"account.created">>, _Payload}, State) ->
    Pid ! {binding_result, true, ?VIEW_FILE},
    {noreply, State};

handle_info({binding_fired, Pid, _false, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(timeout, State) ->
    bind_to_crossbar(),
    whapps_util:update_all_accounts(?VIEW_FILE),
    {noreply, State};

handle_info(_Info, State) ->
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
-spec(bind_to_crossbar/0 :: () ->  no_return()).
bind_to_crossbar() ->
    _ = crossbar_bindings:bind(<<"v1_resource.content_types_provided.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.vmboxes">>),
    _ = crossbar_bindings:bind(<<"v1_resource.execute.#.vmboxes">>),
    crossbar_bindings:bind(<<"account.created">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add content types accepted and provided by this module
%%
%% @end
%%--------------------------------------------------------------------
content_types_provided([_,?MESSAGES_RESOURCE, _, ?BIN_DATA], #cb_context{req_verb = <<"get">>}=Context) ->
    CTP = [{to_binary, ?MEDIA_MIME_TYPES}],
    Context#cb_context{content_types_provided=CTP};
content_types_provided(_, Context) -> Context.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec(allowed_methods/1 :: (Paths :: list()) -> tuple(boolean(), http_methods())).
allowed_methods([]) ->
    {true, ['GET', 'PUT']};
allowed_methods([_]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, ?MESSAGES_RESOURCE]) ->
    {true, ['GET']};
allowed_methods([_, ?MESSAGES_RESOURCE, _]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, ?MESSAGES_RESOURCE, _, ?BIN_DATA]) ->
    {true, ['GET']};
allowed_methods(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec(resource_exists/1 :: (Paths :: list()) -> tuple(boolean(), [])).
resource_exists([]) ->
    {true, []};
resource_exists([_]) ->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE])->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE, _])->
    {true, []};
resource_exists([_, ?MESSAGES_RESOURCE, _, ?BIN_DATA])->
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
validate([], #cb_context{req_verb = <<"get">>}=Context) ->
    load_vmbox_summary(Context);
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    create_vmbox(Context);
validate([DocId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_vmbox(DocId, Context);
validate([DocId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_vmbox(DocId, Context);
validate([DocId], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_vmbox(DocId, Context);

validate([DocId, ?MESSAGES_RESOURCE], #cb_context{req_verb = <<"get">>}=Context) ->
    load_message_summary(DocId, Context);

validate([DocId, ?MESSAGES_RESOURCE, AttachmentId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_message(DocId, AttachmentId, Context);

validate([DocId, ?MESSAGES_RESOURCE, AttachmentId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_message(DocId, AttachmentId, Context);

validate([DocId, ?MESSAGES_RESOURCE, AttachmentId], #cb_context{req_verb = <<"delete">>}=Context) ->
    delete_message(DocId, AttachmentId, Context);

validate([DocId, ?MESSAGES_RESOURCE, AttachmentId, ?BIN_DATA], #cb_context{req_verb = <<"get">>}=Context) ->
    get_message_binary(DocId, AttachmentId, Context);

validate(_Other, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_vmbox_summary/1 :: (Context) -> #cb_context{} when
      Context :: #cb_context{}.
load_vmbox_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new vmbox document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec(create_vmbox/1 :: (Context :: #cb_context{}) -> #cb_context{}).
create_vmbox(#cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, _} ->
            Context#cb_context{
	      doc=wh_json:set_value(<<"pvt_type">>, <<"vmbox">>, JObj)
	      ,resp_status=success
	     }
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a vmbox document from the database
%% @end
%%--------------------------------------------------------------------
-spec(load_vmbox/2 :: (DocId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_vmbox(DocId, Context) ->
    crossbar_doc:load(DocId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing vmbox document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec(update_vmbox/2 :: (DocId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_vmbox(DocId, #cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, _} ->
            crossbar_doc:load_merge(DocId, JObj, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec(normalize_view_results/2 :: (JObj :: json_object(), Acc :: json_objects()) -> json_objects()).
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(is_valid_doc/1 :: (JObj :: json_object()) -> tuple(boolean(), list(binary()))).
is_valid_doc(JObj) ->
    {(wh_json:get_value(<<"mailbox">>, JObj) =/= undefined), [<<"mailbox">>]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get messages summary for a given mailbox
%% @end
%%--------------------------------------------------------------------
-spec(load_message_summary/2 :: (DocId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_message_summary(DocId, Context) ->
    case load_messages_from_doc(DocId, Context) of
	[] ->
	    crossbar_util:response(error, no_messages_attached, Context);
	[?EMPTY_JSON_OBJECT] ->
	    crossbar_util:response(error, no_messages_attached, Context);
	Messages ->
	    crossbar_util:response(Messages,Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get message by its attachment ID (ie attachmentid.wav)
%% @end
%%--------------------------------------------------------------------
-spec(load_message/3 :: (DocId :: binary(), AttachmentId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_message(DocId, AttachmentId, Context) ->
    Messages = load_messages_from_doc(DocId, Context),
    Attachment = attachment_name(AttachmentId),

    case load_message(Attachment, Messages) of
	{struct, _}=Message ->
	    crossbar_util:response(Message,Context);
	no_message ->
	    crossbar_util:response_bad_identifier(AttachmentId, Context)
    end.

load_message(Attachment, Messages) ->
    case [Message || Message <- Messages, wh_json:get_value(<<"attachment">>, Message ) =:= Attachment] of
	[Mess | _] -> Mess;
	[] -> no_message
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get message binary content so it can be downloaded
%% @end
%%--------------------------------------------------------------------
-spec(get_message_binary/3 :: (DocId :: binary(), AttachmentId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
get_message_binary(DocId, AttachmentId, Context) ->
    crossbar_doc:load_attachment(DocId, attachment_name(AttachmentId), Context).
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get full attachment name from its ID
%% @end
%%--------------------------------------------------------------------
-spec(attachment_name/1 :: (AttachmentId :: binary()) -> binary()).
attachment_name(AttachmentId) ->
    <<AttachmentId/binary, ?MESSAGE_AUDIO_EXT/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% DELETE the message (set folder prop to deleted)
%% @end
%%--------------------------------------------------------------------\
-spec(delete_message/3 :: (DocId :: binary(), AttachmentId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
delete_message(DocId, AttachmentId, Context) ->
    Context1 = #cb_context{doc=Doc} = crossbar_doc:load(DocId, Context),
    Messages = wh_json:get_value(<<"messages">>, Doc),

    case get_message_index(AttachmentId, Messages) of
	Index when Index > 0 ->
	    Doc1 = wh_json:set_value([<<"messages">>, Index, <<"folder">>], <<"deleted">>, Doc),
	    Context1#cb_context{doc=Doc1};
	0 ->
	    crossbar_util:response_bad_identifier(AttachmentId, Context)
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initiate the recursive search of the message index
%%
%% @end
%%--------------------------------------------------------------------
-spec(get_message_index/2 :: (AttachmentId :: binary(), Messages :: json_objects()) -> non_neg_integer()).
get_message_index(AttachmentId, Messages) ->
    find_index(AttachmentId, Messages, 1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Recursively finds the index of message
%%
%% @end
%%--------------------------------------------------------------------
-spec(find_index/3 :: (AttachmentId :: binary(), list(), Index :: non_neg_integer()) -> non_neg_integer()).
find_index(_, [], _) ->
    0;
find_index(AttachmentId, [Messages | Other], Index) ->
    case wh_json:get_value(<<"attachment">>, Messages) =:= attachment_name(AttachmentId) of
	true ->
	    Index;
	false ->
	    find_index(AttachmentId, Other, Index + 1)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update the message informations
%% Only Folder prop is editable atm
%% @end
%%--------------------------------------------------------------------
-spec(update_message/3 :: (DocId :: binary(), AttachmentId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_message(DocId, AttachmentId, #cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, _} ->
	    update_message1(DocId, AttachmentId, Context)
    end.

update_message1(DocId, AttachmentId, Context) ->
    RequestedValue = wh_json:get_value(<<"folder">>, Context#cb_context.req_data),
    Context1 = #cb_context{doc=Doc} = crossbar_doc:load(DocId, Context),
    Messages = wh_json:get_value(<<"messages">>, Doc),

    case get_message_index(AttachmentId, Messages) of
  	Index when Index > 0 ->
	    Doc1 = wh_json:set_value([<<"messages">>, Index, <<"folder">>], RequestedValue, Doc),
	    Context1#cb_context{doc=Doc1};
	0 ->
	    crossbar_util:response_bad_identifier(AttachmentId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns associated Messages as a List of json obj
%% @end
%%--------------------------------------------------------------------
-spec(load_messages_from_doc/2 :: (DocId :: binary(), Context :: #cb_context{}) -> json_objects()).
load_messages_from_doc(DocId, Context) ->
    #cb_context{doc=Doc} = crossbar_doc:load(DocId, Context),
    wh_json:get_value(<<"messages">>, Doc).

%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%% API resource
%%%
%%%
%%% @end
%%% Created :  05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%------------------------------------------------------------------- 
-module(v1_resource).

-export([init/1]).
-export([to_json/2, to_xml/2, to_binary/2]).
-export([from_json/2, from_xml/2, from_form/2, from_binary/2]).
-export([encodings_provided/2, finish_request/2, is_authorized/2, forbidden/2, allowed_methods/2]).
-export([malformed_request/2, content_types_provided/2, content_types_accepted/2, resource_exists/2]).
-export([allow_missing_post/2, post_is_create/2, create_path/2, options/2]).
-export([expires/2, generate_etag/2]).
-export([process_post/2, delete_resource/2]).

-include("crossbar.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-define(NAME, <<"v1_resource">>).

%%%===================================================================
%%% WebMachine API
%%%===================================================================
init(Opts) ->
    {Context, _} = crossbar_bindings:fold(<<"v1_resource.init">>, {#cb_context{start=now()}, Opts}),
    {ok, Context}.
    %% {{trace, "/tmp"}, Context}.
    %% wmtrace_resource:add_dispatch_rule("wmtrace", "/tmp"). % in your running shell to look at trace files
    %% binds http://host/wmtrace and stores the files in /tmp
    %% wmtrace_resource:remove_dispatch_rules/0 removes the trace rule

allowed_methods(RD, #cb_context{allowed_methods=Methods}=Context) ->    
    Context1 = case wrq:get_req_header("Content-Type", RD) of
		   "multipart/form-data" ++ _ ->
		       extract_files_and_params(RD, Context);
		   "application/json" ++ _ ->
		       Context#cb_context{req_json=get_json_body(RD)};
		   "application/x-json" ++ _ ->
		       Context#cb_context{req_json=get_json_body(RD)};
		   _ ->
		       extract_file(RD, Context#cb_context{req_json=get_json_body(RD)})
	       end,

    Verb = get_http_verb(RD, Context1#cb_context.req_json),
    Tokens = lists:map(fun whistle_util:to_binary/1, wrq:path_tokens(RD)),

    logger:format_log(info, "v1: Processing new request ~p as ~p but treating as ~p", [
                                                                                       wrq:raw_path(RD),
                                                                                       wrq:method(RD),
                                                                                       Verb
                                                                                      ]),
    logger:format_log(info, "v1: Payload ~p", [Context1#cb_context.req_json]),

    case parse_path_tokens(Tokens) of
        [{Mod, Params}|_] = Nouns ->            
            Responses = crossbar_bindings:map(<<"v1_resource.allowed_methods.", Mod/binary>>, Params),
            Methods1 = allow_methods(Responses, Methods, Verb, wrq:method(RD)),            
            case is_cors_preflight(RD) of
                true ->
                    {['OPTIONS'], RD, Context1#cb_context{req_nouns=Nouns, req_verb=Verb, allow_methods=Methods1}};
                false ->
                    {Methods1 , RD, Context1#cb_context{req_nouns=Nouns, req_verb=Verb, allow_methods=Methods1}}
            end;
        [] ->
            {Methods, RD, Context1#cb_context{req_verb=Verb}}
    end.

-spec(malformed_request/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(boolean(), #wm_reqdata{}, #cb_context{})).
malformed_request(RD, #cb_context{req_json={malformed, ErrBin}}=Context) ->
    Context1 = Context#cb_context{
		 resp_status = error
		 ,resp_error_msg = <<"Invalid or malformed content: ", ErrBin/binary>>
		     ,resp_error_code = 400
		},
    Content = create_resp_content(RD, Context1),
    RD1 = wrq:set_resp_body(Content, RD),
    {true, RD1, Context1};
malformed_request(RD, #cb_context{req_json=Json, req_verb=Verb}=Context) ->
    Data = whapps_json:get_value(["data"], Json),
    Auth = get_auth_token(RD, whapps_json:get_value(<<"auth_token">>, Json, <<>>), Verb),
    {false, RD, Context#cb_context{req_json=Json, req_data=Data, auth_token=Auth}}.

is_authorized(RD, #cb_context{auth_token=AuthToken}=Context) ->
    S0 = crossbar_session:start_session(AuthToken),
    Event = <<"v1_resource.start_session">>,
    S = crossbar_bindings:fold(Event, S0),
    {true, RD, Context#cb_context{session=S}}.

forbidden(RD, Context) ->
    case is_authentic(RD, Context) of
        {true, RD1, Context1} ->         
            case is_permitted(RD1, Context1) of
                {true, RD2, Context2} ->
                    {false, RD2, Context2};
                false ->
                    {true, RD1, Context1}
            end;
        false ->
            {{halt, 401}, RD, Context}
    end.

resource_exists(RD, #cb_context{req_nouns=[{<<"404">>,_}|_]}=Context) ->
    logger:format_log(info, "v1: requested resource with no nouns", []),
    {false, RD, Context};
resource_exists(RD, Context) ->
    case does_resource_exist(RD, Context) of
	true ->
            {RD1, Context1} = validate(RD, Context),
            case succeeded(Context1) of
                true ->
                    logger:format_log(info, "v1: requested resource validated", []),
                    execute_request(add_cors_headers(RD1, Context1), Context1);
                false ->
                    logger:format_log(info, "v1: requested resource did not validate", []),
                    Content = create_resp_content(RD, Context1),
                    RD2 = wrq:append_to_response_body(Content, RD1),
                    ReturnCode = Context1#cb_context.resp_error_code,
                    {{halt, ReturnCode}, wrq:remove_resp_header("Content-Encoding", RD2), Context1}
            end;
	false ->
            logger:format_log(info, "v1: requested resource does not exist", []),
	    {false, RD, Context}
    end.

options(RD, Context)->            
    {get_cors_headers(Context), RD, Context}.

%% each successive cb module adds/removes the content types they provide (to be matched against the request Accept header)
content_types_provided(RD, #cb_context{req_nouns=Nouns}=Context) ->
    Context1 = lists:foldr(fun({Mod, Params}, Context0) ->
				   Event = <<"v1_resource.content_types_provided.", Mod/binary>>,
				   Payload = {RD, Context0, Params},
				   {_, Context01, _} = crossbar_bindings:fold(Event, Payload),
				   Context01
			   end, Context, Nouns),
    CTP = lists:foldr(fun({Fun, L}, Acc) ->
			      lists:foldr(fun(EncType, Acc1) -> [ {EncType, Fun} | Acc1 ] end, Acc, L)
		      end, [], Context1#cb_context.content_types_provided),
    {CTP, RD, Context1}.

content_types_accepted(RD, #cb_context{req_nouns=Nouns}=Context) ->
    Context1 = lists:foldr(fun({Mod, Params}, Context0) ->
				   Event = <<"v1_resource.content_types_accepted.", Mod/binary>>,
				   Payload = {RD, Context0, Params},
				   {_, Context01, _} = crossbar_bindings:fold(Event, Payload),
				   Context01
			   end, Context, Nouns),
    CTA = lists:foldr(fun({Fun, L}, Acc) ->
			      lists:foldr(fun(EncType, Acc1) -> [ {EncType, Fun} | Acc1 ] end, Acc, L)
		      end, [], Context1#cb_context.content_types_accepted),
    {CTA, RD, Context1}.

generate_etag(RD, Context) ->
    Event = <<"v1_resource.etag">>,
    {RD1, Context1} = crossbar_bindings:fold(Event, {RD, Context}),
    case Context1#cb_context.resp_etag of
        automatic ->
            RespContent = create_resp_content(RD, Context1),
            {mochihex:to_hex(crypto:md5(RespContent)), RD, Context1};
        undefined ->
            {undefined, RD1, Context1};
        Tag when is_list(Tag) ->
            {undefined, RD1, Context1}
    end.

encodings_provided(RD, Context) ->
    { [ {"identity", fun(X) -> X end} ]
      ,RD, Context}.

expires(RD, #cb_context{resp_expires=Expires}=Context) ->
    Event = <<"v1_resource.expires">>,
    crossbar_bindings:fold(Event, {Expires, RD, Context}).

process_post(RD, Context) ->
    Event = <<"v1_resource.process_post">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

delete_resource(RD, Context) ->
    Event = <<"v1_resource.delete_resource">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

finish_request(RD, #cb_context{start=T1, session=undefined}=Context) ->
    Event = <<"v1_resource.finish_request">>,
    {RD1, Context1} = crossbar_bindings:fold(Event, {RD, Context}),
    logger:format_log(info, "Request fulfilled in ~p ms~n", [timer:now_diff(now(), T1)*0.001]),
    {true, RD1, Context1};
finish_request(RD, #cb_context{start=T1, session=S}=Context) ->
    Event = <<"v1_resource.finish_request">>,
    {RD1, Context1} = crossbar_bindings:fold(Event, {RD, Context}),
    logger:format_log(info, "Request fulfilled in ~p ms, finish session~n", [timer:now_diff(now(), T1)*0.001]),
    {true, crossbar_session:finish_session(S, RD1), Context1#cb_context{session=undefined}}.

%%%===================================================================
%%% Content Acceptors
%%%===================================================================
from_json(RD, Context) ->
    Event = <<"v1_resource.from_json">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

from_xml(RD, Context) ->
    Event = <<"v1_resource.from_xml">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

from_form(RD, Context) ->
    Event = <<"v1_resource.from_form">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

from_binary(RD, Context) ->
    Event = <<"v1_resource.from_binary">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

%%%===================================================================
%%% Content Providers
%%%===================================================================
-spec(to_json/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(iolist() | tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
to_json(RD, Context) ->
    Event = <<"v1_resource.to_json">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_pull_response(RD, Context).

-spec(to_xml/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(iolist() | tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
to_xml(RD, Context) ->
    Event = <<"v1_resource.to_xml">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    create_pull_response(RD, Context).

-spec(to_binary/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(iolist() | tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
to_binary(RD, #cb_context{resp_data=RespData}=Context) ->
    Event = <<"v1_resource.to_binary">>,
    _ = crossbar_bindings:map(Event, {RD, Context}),
    {RespData, set_resp_headers(RD, Context), Context}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will loop over the Tokens in the request path and return
%% a proplist with keys being the module and values a list of parameters
%% supplied to that module.  If the token order is improper a empty list
%% is returned.
%% @end
%%--------------------------------------------------------------------
-spec(parse_path_tokens/1 :: (Tokens :: list()) -> proplist()).
parse_path_tokens(Tokens) ->
    Loaded = lists:map(fun({Mod, _, _, _}) -> whistle_util:to_binary(Mod) end, supervisor:which_children(crossbar_module_sup)),
    parse_path_tokens(Tokens, Loaded, []).

-spec(parse_path_tokens/3 :: (Tokens :: list(), Loaded :: list(), Events :: list()) -> proplist()).
parse_path_tokens([], _Loaded, Events) ->
    Events;
parse_path_tokens([Mod|T], Loaded, Events) ->
    case lists:member(Mod, Loaded) of
        false ->
            parse_path_tokens([], Loaded, []);
        true ->
            {Params, List2} = lists:splitwith(fun(Elem) -> not lists:member(Elem, Loaded) end, T),
            Params1 = [ whistle_util:to_binary(P) || P <- Params ],
            parse_path_tokens(List2, Loaded, [{Mod, Params1} | Events])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check whether we need to change the HTTP verb to send to the crossbar
%% modules. Only valid for POST requests, and only to change it from
%% POST to PUT or DELETE.
%% @end
%%--------------------------------------------------------------------
-spec(get_http_verb/2 :: (RD :: #wm_reqdata{}, JSON :: json_object() | malformed) -> binary()).
get_http_verb(RD, {malformed, _}) ->
    whistle_util:to_binary(string:to_lower(atom_to_list(wrq:method(RD))));
get_http_verb(RD, JSON) ->
    HttpV = whistle_util:to_binary(string:to_lower(atom_to_list(wrq:method(RD)))),
    case override_verb(RD, JSON, HttpV) of
	{true, OverrideV} -> OverrideV;
	false -> HttpV
    end.

-spec(override_verb/3 :: (RD :: #wm_reqdata{}, JSON :: json_object(), Verb :: binary()) -> tuple(true, binary()) | false).
override_verb(RD, JSON, <<"post">>) ->
    case whapps_json:get_value(<<"verb">>, JSON) of
	undefined ->
	    case wrq:get_qs_value("verb", RD) of
		undefined -> false;
		V -> {true, whistle_util:to_binary(string:to_lower(V))}
	    end;
	V -> {true, whistle_util:to_binary(string:to_lower(binary_to_list(V)))}
    end;
override_verb(RD, _, <<"options">>) ->
    case wrq:get_req_header("Access-Control-Request-Method", RD) of
        undefined -> false;

        V -> {true, whistle_util:to_binary(string:to_lower(V))}
    end;
override_verb(_, _, _) -> false.

-spec(get_json_body/1 :: (RD :: #wm_reqdata{}) -> json_object() | tuple(malformed, binary())).
get_json_body(RD) ->
    try
	QS = [ {whistle_util:to_binary(K), whistle_util:to_binary(V)} || {K,V} <- wrq:req_qs(RD)],
	case wrq:req_body(RD) of
	    <<>> -> {struct, QS};
	    ReqBody ->
		{struct, Prop} = JSON = mochijson2:decode(ReqBody),
		case is_valid_request_envelope(JSON) of
		    true -> {struct, Prop ++ QS};
		    false -> {malformed, <<"Invalid request envelope">>}
		end
	end
    catch
	_:{badmatch, {comma,{decoder,_,S,_,_,_}}} ->
	    {malformed, list_to_binary(["Failed to decode: comma error around char ", whistle_util:to_list(S)])};
	_:E ->
	    logger:format_log(error, "v1_resource: failed to convert to json(~p)~n", [E]),
	    {malformed, <<"JSON failed to validate; check your commas and curlys">>}
    end.

-spec(extract_files_and_params/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> #cb_context{}).
extract_files_and_params(RD, Context) ->
    try
	Boundry = webmachine_multipart:find_boundary(RD),
	logger:format_log(info, "v1: extracting files with boundry: ~p~n", [Boundry]),
	{ReqProp, FilesProp} = get_streamed_body(
				 webmachine_multipart:stream_parts(
				   wrq:stream_req_body(RD, 1024), Boundry), [], []),
	Context#cb_context{req_json={struct, ReqProp}, req_files=FilesProp}
    catch
	A:B ->
	    logger:format_log(error, "v1.extract_files_and_params: exception ~p:~p~n~p~n", [A, B, erlang:get_stacktrace()]),
	    Context
    end.

-spec(extract_file/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> #cb_context{}).
extract_file(RD, Context) ->
    logger:format_log(info, "v1: extracting files (if any)~n", []),
    FileContents = whistle_util:to_binary(wrq:req_body(RD)),
    ContentType = wrq:get_req_header("Content-Type", RD),
    ContentSize = wrq:get_req_header("Content-Length", RD),
    Context#cb_context{req_files=[{<<"uploaded_file">>, {struct, [{<<"headers">>, {struct, [{<<"content-type">>, ContentType}
											    ,{<<"content-length">>, ContentSize}
											   ]}}
								  ,{<<"contents">>, FileContents}
								 ]}
				  }]
		      }.

-spec(get_streamed_body/3 :: (Term :: term(), ReqProp :: proplist(), FilesProp :: proplist()) -> tuple(proplist(), proplist())).
get_streamed_body(done_parts, ReqProp, FilesProp) ->
    {ReqProp, FilesProp};
get_streamed_body({{_, {Params, []}, Content}, Next}, ReqProp, FilesProp) ->
    Key = whistle_util:to_binary(props:get_value(<<"name">>, Params)),
    Value = binary:replace(whistle_util:to_binary(Content), <<$\r,$\n>>, <<>>, [global]),
    get_streamed_body(Next(), [{Key, Value} | ReqProp], FilesProp);
get_streamed_body({{_, {Params, Hdrs}, Content}, Next}, ReqProp, FilesProp) ->
    Key = whistle_util:to_binary(props:get_value(<<"name">>, Params)),
    FileName = whistle_util:to_binary(props:get_value(<<"filename">>, Params)),

    Value = whistle_util:to_binary(Content),

    get_streamed_body(Next(), ReqProp, [{Key, {struct, [{<<"headers">>, {struct, Hdrs}}
							,{<<"contents">>, Value}
							,{<<"filename">>, FileName}
						       ]}}
					| FilesProp]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will find the intersection of the allowed methods
%% among event respsonses.  The responses can only veto the list of
%% methods, they can not add.
%%
%% If a client passes a ?verb=(PUT|DELETE) on a POST request, ReqVerb will
%% be <<"put">> or <<"delete">>, while HttpVerb is 'POST'. If the allowed
%% methods do not include 'POST', we need to add it if allowed methods include
%% the verb in ReqVerb.
%% So, POSTing a <<"put">>, and the allowed methods include 'PUT', insert POST
%% as well.
%% POSTing a <<"delete">>, and 'DELETE' is NOT in the allowed methods, remove
%% 'POST' from the allowed methods.
%% @end
%%--------------------------------------------------------------------
-spec(allow_methods/4  :: (Reponses :: list(tuple(term(), term())), Avaliable :: http_methods(), ReqVerb :: binary(), HttpVerb :: atom()) -> http_methods()).
allow_methods(Responses, Available, ReqVerb, HttpVerb) ->
    case crossbar_bindings:succeeded(Responses) of
        [] ->
	    Available;
	Succeeded ->
	    Allowed = lists:foldr(fun({true, Response}, Acc) ->
					  Set1 = sets:from_list(Acc),
					  Set2 = sets:from_list(Response),
					  sets:to_list(sets:intersection(Set1, Set2))
				  end, Available, Succeeded),
            add_post_method(ReqVerb, HttpVerb, Allowed)
    end.

%% insert 'POST' if Verb is in Allowed; otherwise remove 'POST'.
add_post_method(Verb, 'POST', Allowed) ->
    VerbAtom = list_to_atom(string:to_upper(binary_to_list(Verb))),
    case lists:member(VerbAtom, Allowed) of
	true -> ['POST' | Allowed];
	false -> lists:delete('POST', Allowed)
    end;
add_post_method(_, _, Allowed) ->
    Allowed.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will look for the authorization token, first checking the
%% request headers, if not found there it will look either in the HTTP
%% query paramerts (for GET and DELETE) or HTTP content (for POST and PUT)
%% @end
%%--------------------------------------------------------------------
-spec(get_auth_token/3 :: (RD :: #wm_reqdata{}, JsonToken :: binary(), Verb :: binary()) -> binary()).
get_auth_token(RD, JsonToken, Verb) ->
    case wrq:get_req_header("X-Auth-Token", RD) of
        undefined ->
            case Verb of
                <<"get">> ->
                    whistle_util:to_binary(props:get_value("auth_token", wrq:req_qs(RD), <<>>));
		_ ->
		    JsonToken
	    end;
        AuthToken ->
            whistle_util:to_binary(AuthToken)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Determines if the request envelope is valid
%% @end
%%--------------------------------------------------------------------
-spec(is_valid_request_envelope/1 :: (JSON :: json_object()) -> boolean()).
is_valid_request_envelope(JSON) ->
    whapps_json:get_value([<<"data">>], JSON, not_found) =/= not_found.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the target noun
%% (the final module in the chain) accepts this verb parameter pair.
%% @end
%%--------------------------------------------------------------------
-spec(does_resource_exist/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> boolean()).
does_resource_exist(_RD, #cb_context{req_nouns=[{Mod, Params}|_]}) ->
    Event = <<"v1_resource.resource_exists.", Mod/binary>>,
    Responses = crossbar_bindings:map(Event, Params),
    crossbar_bindings:all(Responses) and true;
does_resource_exist(_RD, _Context) ->
    false.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client has
%% provided a valid authentication token
%% @end
%%--------------------------------------------------------------------
-spec(is_authentic/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> false | tuple(true, #wm_reqdata{}, #cb_context{})).
is_authentic(RD, Context)->
    case wrq:method(RD) of
        %% all all OPTIONS, they are harmless (I hope) and required for CORS preflight
        'OPTIONS' ->
            {true, RD, Context};
        _ ->
            Event = <<"v1_resource.authenticate">>,
            case crossbar_bindings:succeeded(crossbar_bindings:map(Event, {RD, Context})) of
                [] ->
                    false;
                [{true, {RD1, Context1}}|_] -> 
                    {true, RD1, Context1}
            end
    end.
            
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client is
%% authorized for this request
%% @end
%%--------------------------------------------------------------------
-spec(is_permitted/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> false | tuple(true, #wm_reqdata{}, #cb_context{})).
is_permitted(RD, Context)->
    case wrq:method(RD) of 
        %% all all OPTIONS, they are harmless (I hope) and required for CORS preflight
        'OPTIONS' ->
            {true, RD, Context};
        _ ->
            Event = <<"v1_resource.authorize">>,
            case crossbar_bindings:succeeded(crossbar_bindings:map(Event, {RD, Context})) of
                [] ->
            false;
                [{true, {RD1, Context1}}|_] -> 
                    {true, RD1, Context1}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function gives each noun a chance to determine if
%% it is valid and returns the status, and any errors
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(#wm_reqdata{}, #cb_context{})).
validate(RD, #cb_context{req_nouns=Nouns}=Context) ->
    lists:foldr(fun({Mod, Params}, {RD1, Context1}) ->
			Event = <<"v1_resource.validate.", Mod/binary>>,
                        Payload = [RD1, Context1] ++ Params,
			[RD2, Context2 | _] = crossbar_bindings:fold(Event, Payload),
			{RD2, Context2}
                end, {RD, Context}, Nouns).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will execute the request
%% @end
%%--------------------------------------------------------------------
-spec(execute_request/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(true|tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
execute_request(RD, #cb_context{req_nouns=[{Mod, Params}|_], req_verb=Verb}=Context) ->
    Event = <<"v1_resource.execute.", Verb/binary, ".", Mod/binary>>,
    Payload = [RD, Context] ++ Params,
    logger:format_log(info, "Execute request ~p", [Event]),
    [RD1, Context1 | _] = crossbar_bindings:fold(Event, Payload),
    case succeeded(Context1) of
        false ->
            logger:format_log(info, "v1: failed to execute ~p req for ~p: ~p~n", [Verb, Mod, Params]),
            Content = create_resp_content(RD1, Context1),
            RD2 = wrq:append_to_response_body(Content, RD1),
            ReturnCode = Context1#cb_context.resp_error_code,
            {{halt, ReturnCode}, wrq:remove_resp_header("Content-Encoding", RD2), Context1};
        true ->
            logger:format_log(info, "v1: executed ~p req for ~p: ~p~n", [Verb, Mod, Params]),
	    {Verb =/= <<"put">>, RD1, Context1}
    end;
execute_request(RD, Context) ->
    {false, RD, Context}.

%% If we're tunneling PUT through POST, we need to tell webmachine POST is allowed to create a non-existant resource
%% AKA, 201 Created header set
allow_missing_post(RD, Context) ->
    {wrq:method(RD) =:= 'POST', RD, Context}.

%% If allow_missing_post returned true (cause it was a POST) and PUT has been tunnelled,
%% POST is a create
post_is_create(RD, #cb_context{req_verb = <<"put">>}=Context) ->
    {true, RD, Context};
post_is_create(RD, Context) ->
    {false, RD, Context}.

%% whatever (for now)
create_path(RD, Context) ->
    {[], RD, Context}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create the content for the response body
%% @end
%%--------------------------------------------------------------------
-spec(create_resp_content/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> iolist()).
create_resp_content(RD, #cb_context{req_json=ReqJson}=Context) ->
    case get_resp_type(RD) of
	xml ->
	    Prop = create_resp_envelope(Context),
            io_lib:format("<?xml version=\"1.0\"?><crossbar>~s</crossbar>", [encode_xml(lists:reverse(Prop), [])]);
        json ->
	    Prop = create_resp_envelope(Context),
            JSON = mochijson2:encode({struct, Prop}),
	    case whapps_json:get_value(<<"jsonp">>, ReqJson) of
		undefined -> JSON;
		JsonFun when is_binary(JsonFun) ->
		    [JsonFun, "(", JSON, ");"]
	    end;
	binary ->
	    Context#cb_context.resp_data
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create response expected for a request that
%% is pushing data (like PUT)
%% @end
%%--------------------------------------------------------------------
-spec(create_push_response/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(boolean(), #wm_reqdata{}, #cb_context{})).
create_push_response(RD, Context) ->
    Content = create_resp_content(RD, Context),
    RD1 = set_resp_headers(RD, Context),
    {succeeded(Context), wrq:set_resp_body(Content, RD1), Context}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create response expected for a request that
%% is pulling data (like GET)
%% @end
%%--------------------------------------------------------------------
-spec(create_pull_response/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(iolist() | tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
create_pull_response(RD, Context) ->
    Content = create_resp_content(RD, Context),
    RD1 = set_resp_headers(RD, Context),
    case succeeded(Context) of
        false ->
            {{halt, 500}, wrq:set_resp_body(Content, RD1), Context};
        true ->
            {Content, RD, Context}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the response is of type success
%% @end
%%--------------------------------------------------------------------
-spec(succeeded/1 :: (Context :: #cb_context{}) -> boolean()).
succeeded(#cb_context{resp_status=success}) ->
    true;
succeeded(_) ->
    false.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Iterate through #cb_context.resp_headers, setting the headers specified
%% @end
%%--------------------------------------------------------------------
-spec(set_resp_headers/2 :: (RD0 :: #wm_reqdata{}, Context :: #cb_context{}) -> #wm_reqdata{}).
set_resp_headers(RD0, #cb_context{resp_headers=[]}) -> RD0;
set_resp_headers(RD0, #cb_context{resp_headers=Headers}) ->
    logger:format_log(info, "v1.set_resp_headers: ~p~n", [Headers]),
    lists:foldl(fun({Header, Value}, RD) ->
			{H, V} = fix_header(RD, Header, Value),
			wrq:set_resp_header(H, V, wrq:remove_resp_header(H, RD))
		end, RD0, Headers).

-spec(fix_header/3 :: (RD :: #wm_reqdata{}, Header :: string(), Value :: string() | binary()) -> tuple(string(), string())).
fix_header(RD, "Location"=H, Url) ->
    %% http://some.host.com:port/"
    Port = case wrq:port(RD) of
	       80 -> "";
	       P -> [":", whistle_util:to_list(P)]
	   end,

    logger:format_log(info, "v1.fix_header: host_tokens: ~p~n", [wrq:host_tokens(RD)]),
    Host = ["http://", string:join(lists:reverse(wrq:host_tokens(RD)), "."), Port, "/"],
    logger:format_log(info, "v1.fix_header: host: ~s~n", [Host]),

    %% /v1/accounts/acct_id/module => [module, acct_id, accounts, v1]
    PathTokensRev = lists:reverse(string:tokens(wrq:path(RD), "/")),
    UrlTokens = string:tokens(whistle_util:to_list(Url), "/"),

    Url1 =
	string:join(
	  lists:reverse(
	    lists:foldl(fun("..", []) -> [];
			   ("..", [_ | PathTokens]) -> PathTokens;
			   (".", PathTokens) -> PathTokens;
			   (Segment, PathTokens) -> [Segment | PathTokens]
			end, PathTokensRev, UrlTokens)
	   ), "/"),

    {H, lists:concat([Host | [Url1]])};
fix_header(_, H, V) ->
    {whistle_util:to_list(H), whistle_util:to_list(V)}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to determine if this is a cross origin resource sharing
%% request
%% @end
%%--------------------------------------------------------------------
-spec(is_cors_request/1 :: (RD :: #wm_reqdata{}) -> boolean()).
is_cors_request(RD) ->
    wrq:get_req_header("Origin", RD) =/= 'undefined' 
        orelse wrq:get_req_header("Access-Control-Request-Method", RD) =/= 'undefined' 
        orelse wrq:get_req_header("Access-Control-Request-Headers", RD) =/= 'undefined'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(add_cors_headers/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> #wm_reqdata{}).                                 
add_cors_headers(RD, Context) ->
    case is_cors_request(RD) of 
        true ->
            wrq:set_resp_headers(get_cors_headers(Context), RD);
        false ->
            RD
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(get_cors_headers/1 :: (Context :: #cb_context{}) -> proplist()).                                 
get_cors_headers(#cb_context{allow_methods=Allowed}) ->
    [
      {"Access-Control-Allow-Origin", "*"}
     ,{"Access-Control-Allow-Methods", string:join([atom_to_list(A) || A <- Allowed], ", ")}
     ,{"Access-Control-Allow-Headers", "Content-Type, Depth, User-Agent, X-File-Size, X-Requested-With, If-Modified-Since, X-File-Name, Cache-Control, X-Auth-Token"}
     ,{"Access-Control-Max-Age", "86400"}
    ].
   
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempts to determine if this is a cross origin resource preflight
%% request
%% @end
%%--------------------------------------------------------------------
-spec(is_cors_preflight/1 :: (RD :: #wm_reqdata{}) -> boolean()).
is_cors_preflight(RD) ->
    is_cors_request(RD) andalso wrq:method(RD) =:= 'OPTIONS'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function extracts the reponse fields and puts them in a proplist
%% @end
%%--------------------------------------------------------------------
-spec(create_resp_envelope/1 :: (Context :: #cb_context{}) -> proplist()).
create_resp_envelope(#cb_context{resp_status = success}=C) ->
    [{<<"auth-token">>, C#cb_context.auth_token}
     ,{<<"status">>, success}
     ,{<<"data">>, C#cb_context.resp_data}
    ];
create_resp_envelope(#cb_context{resp_error_code = undefined}=C) ->
    Msg = case C#cb_context.resp_error_msg of
	      undefined ->
		  StatusBin = whistle_util:to_binary(C#cb_context.resp_status),
		  <<"Unspecified server error: ", StatusBin/binary>>;
	      Else ->
		  whistle_util:to_binary(Else)
	  end,
    [{<<"auth-token">>, C#cb_context.auth_token}
     ,{<<"status">>, C#cb_context.resp_status}
     ,{<<"message">>, Msg}
     ,{<<"error">>, 500}
     ,{<<"data">>, C#cb_context.resp_data}
    ];
create_resp_envelope(C) ->
    Msg = case C#cb_context.resp_error_msg of
	      undefined ->
		  StatusBin = whistle_util:to_binary(C#cb_context.resp_status),
		  ErrCodeBin = whistle_util:to_binary(C#cb_context.resp_error_code),
		  <<"Unspecified server error: ", StatusBin/binary, "(", ErrCodeBin/binary, ")">>;
	      Else ->
		  whistle_util:to_binary(Else)
	  end,
    [{<<"auth-token">>, C#cb_context.auth_token}
     ,{<<"status">>, C#cb_context.resp_status}
     ,{<<"message">>, Msg}
     ,{<<"error">>, C#cb_context.resp_error_code}
     ,{<<"data">>, C#cb_context.resp_data}
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine the appropriate content format to return
%% based on the request....
%% @end
%%--------------------------------------------------------------------
-spec(get_resp_type/1 :: (RD :: #wm_reqdata{}) -> json|xml|binary).
get_resp_type(RD) ->
    case wrq:get_resp_header("Content-Type", RD) of
        "application/xml" -> xml;
        "application/json" -> json;
        "application/x-json" -> json;
	undefined -> json;
        _Else -> binary
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is used to encode the response proplist in xml
%% @end
%%--------------------------------------------------------------------
-spec(encode_xml/2 :: (Prop :: proplist(), Xml :: iolist()) -> iolist()).
encode_xml([], Xml) ->
    Xml;
encode_xml([{K, V}|T], Xml) ->
    Xml1 =
    if
       is_atom(V) orelse is_binary(V) ->
            case V of
                <<"true">> -> xml_tag(K, "true", "boolean");
                true -> xml_tag(K, "true", "boolean");
                <<"false">> -> xml_tag(K, "false", "boolean");
                false -> xml_tag(K, "true", "boolean");
                _Else -> xml_tag(K, mochijson2:encode(V), "string")
            end;
       is_number(V) ->
           xml_tag(K, mochijson2:encode(V), "number");
       is_list(V) ->
           xml_tag(K, list_to_xml(lists:reverse(V), []), "array");
       true ->
            case V of
                {struct, Terms} ->
                    xml_tag(K, encode_xml(Terms, ""), "object");
                {json, IoList} ->
                    xml_tag(K, encode_xml(IoList, ""), "json")
           end
    end,
    encode_xml(T, Xml1 ++ Xml).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function loops over a list and creates the XML tags for each
%% element
%% @end
%%--------------------------------------------------------------------
-spec(list_to_xml/2 :: (List :: list(), Xml :: iolist()) -> iolist()).
list_to_xml([], Xml) ->
    Xml;
list_to_xml([{struct, Terms}|T], Xml) ->
    Xml1 = xml_tag(encode_xml(Terms, ""), "object"),
    list_to_xml(T, Xml1 ++ Xml);
list_to_xml([E|T], Xml) ->
    Xml1 =
    if
        is_atom(E) orelse is_binary(E) ->
            case E of
                <<"true">> -> xml_tag("true", "boolean");
                true -> xml_tag("true", "boolean");
                <<"false">> -> xml_tag("false", "boolean");
                false -> xml_tag("true", "boolean");
                _Else -> xml_tag(mochijson2:encode(E), "string")
            end;
        is_number(E) -> xml_tag(mochijson2:encode(E), "number");
        is_list(E) -> xml_tag(list_to_xml(lists:reverse(E), ""), "array")
    end,
    list_to_xml(T, Xml1 ++ Xml).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function creates a XML tag, optionaly with the name
%% attribute if called as xml_tag/3
%% @end
%%--------------------------------------------------------------------
-spec(xml_tag/2 :: (Value :: iolist(), Type :: iolist()) -> iolist()).
xml_tag(Value, Type) ->
    io_lib:format("<~s>~s</~s>~n", [Type, Value, Type]).
xml_tag(Key, Value, Type) ->
    io_lib:format("<~s type=\"~s\">~s</~s>~n", [Key, Type, string:strip(Value, both, $"), Key]).


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

-module(rabbit_exchange).
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([recover/0, declare/5, lookup/1, lookup_or_die/1, list/1, info_keys/0,
         info/1, info/2, info_all/1, info_all/2, publish/2]).
-export([add_binding/5, delete_binding/5, list_bindings/1]).
-export([delete/2]).
-export([delete_queue_bindings/1, delete_transient_queue_bindings/1]).
-export([assert_equivalence/5]).
-export([assert_args_equivalence/2]).
-export([check_type/1]).

%% EXTENDED API
-export([list_exchange_bindings/1]).
-export([list_queue_bindings/1]).

-import(mnesia).
-import(sets).
-import(lists).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([name/0, type/0, binding_key/0]).

-type(name() :: rabbit_types:r('exchange')).
-type(type() :: atom()).
-type(binding_key() :: binary()).

-type(bind_res() :: rabbit_types:ok_or_error('queue_not_found' |
                                             'exchange_not_found' |
                                             'exchange_and_queue_not_found')).
-type(inner_fun() ::
        fun((rabbit_types:exchange(), queue()) ->
                   rabbit_types:ok_or_error(rabbit_types:amqp_error()))).

-spec(recover/0 :: () -> 'ok').
-spec(declare/5 ::
        (name(), type(), boolean(), boolean(), rabbit_framing:amqp_table())
        -> rabbit_types:exchange()).
-spec(check_type/1 :: (binary()) -> atom()).
-spec(assert_equivalence/5 ::
        (rabbit_types:exchange(), atom(), boolean(), boolean(),
         rabbit_framing:amqp_table())
        -> 'ok').
-spec(assert_args_equivalence/2 ::
        (rabbit_types:exchange(), rabbit_framing:amqp_table()) -> 'ok').
-spec(lookup/1 ::
        (name()) -> rabbit_types:ok(rabbit_types:exchange()) |
                    rabbit_types:error('not_found')).
-spec(lookup_or_die/1 :: (name()) -> rabbit_types:exchange()).
-spec(list/1 :: (rabbit_types:vhost()) -> [rabbit_types:exchange()]).
-spec(info_keys/0 :: () -> [rabbit_types:info_key()]).
-spec(info/1 :: (rabbit_types:exchange()) -> [rabbit_types:info()]).
-spec(info/2 ::
        (rabbit_types:exchange(), [rabbit_types:info_key()])
        -> [rabbit_types:info()]).
-spec(info_all/1 :: (rabbit_types:vhost()) -> [[rabbit_types:info()]]).
-spec(info_all/2 ::(rabbit_types:vhost(), [rabbit_types:info_key()])
                    -> [[rabbit_types:info()]]).
-spec(publish/2 :: (rabbit_types:exchange(), rabbit_types:delivery())
                   -> {rabbit_router:routing_result(), [pid()]}).
-spec(add_binding/5 ::
        (name(), rabbit_amqqueue:name(), rabbit_router:routing_key(),
         rabbit_framing:amqp_table(), inner_fun())
        -> bind_res()).
-spec(delete_binding/5 ::
        (name(), rabbit_amqqueue:name(), rabbit_router:routing_key(),
         rabbit_framing:amqp_table(), inner_fun())
        -> bind_res() | rabbit_types:error('binding_not_found')).
-spec(list_bindings/1 ::
        (rabbit_types:vhost())
        -> [{name(), rabbit_amqqueue:name(), rabbit_router:routing_key(),
             rabbit_framing:amqp_table()}]).
-spec(delete_queue_bindings/1 ::
        (rabbit_amqqueue:name()) -> fun (() -> none())).
-spec(delete_transient_queue_bindings/1 ::
        (rabbit_amqqueue:name()) -> fun (() -> none())).
-spec(delete/2 ::
        (name(), boolean())-> 'ok' |
                              rabbit_types:error('not_found') |
                              rabbit_types:error('in_use')).
-spec(list_queue_bindings/1 ::
        (rabbit_amqqueue:name())
        -> [{name(), rabbit_router:routing_key(),
             rabbit_framing:amqp_table()}]).
-spec(list_exchange_bindings/1 ::
        (name()) -> [{rabbit_amqqueue:name(), rabbit_router:routing_key(),
                      rabbit_framing:amqp_table()}]).

-endif.

%%----------------------------------------------------------------------------

-define(INFO_KEYS, [name, type, durable, auto_delete, arguments]).

recover() ->
    Exs = rabbit_misc:table_fold(
            fun (Exchange, Acc) ->
                    ok = mnesia:write(rabbit_exchange, Exchange, write),
                    [Exchange | Acc]
            end, [], rabbit_durable_exchange),
    Bs = rabbit_misc:table_fold(
           fun (Route = #route{binding = B}, Acc) ->
                   {_, ReverseRoute} = route_with_reverse(Route),
                   ok = mnesia:write(rabbit_route,
                                     Route, write),
                   ok = mnesia:write(rabbit_reverse_route,
                                     ReverseRoute, write),
                   [B | Acc]
           end, [], rabbit_durable_route),
    recover_with_bindings(Bs, Exs),
    ok.

recover_with_bindings(Bs, Exs) ->
    recover_with_bindings(
      lists:keysort(#binding.exchange_name, Bs),
      lists:keysort(#exchange.name, Exs), []).

recover_with_bindings([B = #binding{exchange_name = Name} | Rest],
                      Xs = [#exchange{name = Name} | _],
                      Bindings) ->
    recover_with_bindings(Rest, Xs, [B | Bindings]);
recover_with_bindings(Bs, [X = #exchange{type = Type} | Xs], Bindings) ->
    (type_to_module(Type)):recover(X, Bindings),
    recover_with_bindings(Bs, Xs, []);
recover_with_bindings([], [], []) ->
    ok.

declare(ExchangeName, Type, Durable, AutoDelete, Args) ->
    Exchange = #exchange{name = ExchangeName,
                         type = Type,
                         durable = Durable,
                         auto_delete = AutoDelete,
                         arguments = Args},
    %% We want to upset things if it isn't ok; this is different from
    %% the other hooks invocations, where we tend to ignore the return
    %% value.
    TypeModule = type_to_module(Type),
    ok = TypeModule:validate(Exchange),
    case rabbit_misc:execute_mnesia_transaction(
           fun () ->
                   case mnesia:wread({rabbit_exchange, ExchangeName}) of
                       [] ->
                           ok = mnesia:write(rabbit_exchange, Exchange, write),
                           ok = case Durable of
                                    true ->
                                        mnesia:write(rabbit_durable_exchange,
                                                     Exchange, write);
                                    false ->
                                        ok
                           end,
                           {new, Exchange};
                       [ExistingX] ->
                           {existing, ExistingX}
                   end
           end) of
        {new, X}      -> TypeModule:create(X),
                         X;
        {existing, X} -> X;
        Err           -> Err
    end.

%% Used with atoms from records; e.g., the type is expected to exist.
type_to_module(T) ->
    case rabbit_exchange_type_registry:lookup_module(T) of
        {ok, Module}       -> Module;
        {error, not_found} -> rabbit_misc:protocol_error(
                                command_invalid,
                                "invalid exchange type '~s'", [T])
    end.

%% Used with binaries sent over the wire; the type may not exist.
check_type(TypeBin) ->
    case rabbit_exchange_type_registry:binary_to_type(TypeBin) of
        {error, not_found} ->
            rabbit_misc:protocol_error(
              command_invalid, "unknown exchange type '~s'", [TypeBin]);
        T ->
            _Module = type_to_module(T),
            T
    end.

assert_equivalence(X = #exchange{ durable = Durable,
                                  auto_delete = AutoDelete,
                                  type = Type},
                   Type, Durable, AutoDelete,
                   RequiredArgs) ->
    ok = (type_to_module(Type)):assert_args_equivalence(X, RequiredArgs);
assert_equivalence(#exchange{ name = Name }, _Type, _Durable, _AutoDelete,
                   _Args) ->
    rabbit_misc:protocol_error(
      not_allowed,
      "cannot redeclare ~s with different type, durable or autodelete value",
      [rabbit_misc:rs(Name)]).

alternate_exchange_value(Args) ->
    lists:keysearch(<<"alternate-exchange">>, 1, Args).

assert_args_equivalence(#exchange{ name = Name,
                                   arguments = Args },
                        RequiredArgs) ->
    %% The spec says "Arguments are compared for semantic
    %% equivalence".  The only arg we care about is
    %% "alternate-exchange".
    Ae1 = alternate_exchange_value(RequiredArgs),
    Ae2 = alternate_exchange_value(Args),
    if Ae1==Ae2 -> ok;
       true     -> rabbit_misc:protocol_error(
                     not_allowed,
                     "cannot redeclare ~s with inequivalent args",
                     [rabbit_misc:rs(Name)])
    end.

lookup(Name) ->
    rabbit_misc:dirty_read({rabbit_exchange, Name}).

lookup_or_die(Name) ->
    case lookup(Name) of
        {ok, X}            -> X;
        {error, not_found} -> rabbit_misc:not_found(Name)
    end.

list(VHostPath) ->
    mnesia:dirty_match_object(
      rabbit_exchange,
      #exchange{name = rabbit_misc:r(VHostPath, exchange), _ = '_'}).

info_keys() -> ?INFO_KEYS.

map(VHostPath, F) ->
    %% TODO: there is scope for optimisation here, e.g. using a
    %% cursor, parallelising the function invocation
    lists:map(F, list(VHostPath)).

infos(Items, X) -> [{Item, i(Item, X)} || Item <- Items].

i(name,        #exchange{name        = Name})       -> Name;
i(type,        #exchange{type        = Type})       -> Type;
i(durable,     #exchange{durable     = Durable})    -> Durable;
i(auto_delete, #exchange{auto_delete = AutoDelete}) -> AutoDelete;
i(arguments,   #exchange{arguments   = Arguments})  -> Arguments;
i(Item, _) -> throw({bad_argument, Item}).

info(X = #exchange{}) -> infos(?INFO_KEYS, X).

info(X = #exchange{}, Items) -> infos(Items, X).

info_all(VHostPath) -> map(VHostPath, fun (X) -> info(X) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (X) -> info(X, Items) end).

publish(X, Delivery) ->
    publish(X, [], Delivery).

publish(X = #exchange{type = Type}, Seen, Delivery) ->
    case (type_to_module(Type)):publish(X, Delivery) of
        {_, []} = R ->
            #exchange{name = XName, arguments = Args} = X,
            case rabbit_misc:r_arg(XName, exchange, Args,
                                   <<"alternate-exchange">>) of
                undefined ->
                    R;
                AName ->
                    NewSeen = [XName | Seen],
                    case lists:member(AName, NewSeen) of
                        true  -> R;
                        false -> case lookup(AName) of
                                     {ok, AX} ->
                                         publish(AX, NewSeen, Delivery);
                                     {error, not_found} ->
                                         rabbit_log:warning(
                                           "alternate exchange for ~s "
                                           "does not exist: ~s",
                                           [rabbit_misc:rs(XName),
                                            rabbit_misc:rs(AName)]),
                                         R
                                 end
                    end
            end;
        R ->
            R
    end.

%% TODO: Should all of the route and binding management not be
%% refactored to its own module, especially seeing as unbind will have
%% to be implemented for 0.91 ?

delete_exchange_bindings(ExchangeName) ->
    [begin
         ok = mnesia:delete_object(rabbit_reverse_route,
                                   reverse_route(Route), write),
         ok = delete_forward_routes(Route),
         Route#route.binding
     end || Route <- mnesia:match_object(
                       rabbit_route,
                       #route{binding = #binding{exchange_name = ExchangeName,
                                                 _ = '_'}},
                       write)].

delete_queue_bindings(QueueName) ->
    delete_queue_bindings(QueueName, fun delete_forward_routes/1).

delete_transient_queue_bindings(QueueName) ->
    delete_queue_bindings(QueueName, fun delete_transient_forward_routes/1).

delete_queue_bindings(QueueName, FwdDeleteFun) ->
    DeletedBindings =
        [begin
             Route = reverse_route(ReverseRoute),
             ok = FwdDeleteFun(Route),
             ok = mnesia:delete_object(rabbit_reverse_route,
                                       ReverseRoute, write),
             Route#route.binding
         end || ReverseRoute
                    <- mnesia:match_object(
                         rabbit_reverse_route,
                         reverse_route(#route{binding = #binding{
                                                queue_name = QueueName,
                                                _          = '_'}}),
                         write)],
    Cleanup = cleanup_deleted_queue_bindings(
                lists:keysort(#binding.exchange_name, DeletedBindings), []),
    fun () ->
            lists:foreach(
              fun ({{IsDeleted, X = #exchange{ type = Type }}, Bs}) ->
                      Module = type_to_module(Type),
                      case IsDeleted of
                          auto_deleted -> Module:delete(X, Bs);
                          not_deleted  -> Module:remove_bindings(X, Bs)
                      end
              end, Cleanup)
    end.

%% Requires that its input binding list is sorted in exchange-name
%% order, so that the grouping of bindings (for passing to
%% cleanup_deleted_queue_bindings1) works properly.
cleanup_deleted_queue_bindings([], Acc) ->
    Acc;
cleanup_deleted_queue_bindings(
  [B = #binding{exchange_name = ExchangeName} | Bs], Acc) ->
    cleanup_deleted_queue_bindings(ExchangeName, Bs, [B], Acc).

cleanup_deleted_queue_bindings(
  ExchangeName, [B = #binding{exchange_name = ExchangeName} | Bs],
  Bindings, Acc) ->
    cleanup_deleted_queue_bindings(ExchangeName, Bs, [B | Bindings], Acc);
cleanup_deleted_queue_bindings(ExchangeName, Deleted, Bindings, Acc) ->
    %% either Deleted is [], or its head has a non-matching ExchangeName
    NewAcc = [cleanup_deleted_queue_bindings1(ExchangeName, Bindings) | Acc],
    cleanup_deleted_queue_bindings(Deleted, NewAcc).

cleanup_deleted_queue_bindings1(ExchangeName, Bindings) ->
    [X] = mnesia:read({rabbit_exchange, ExchangeName}),
    {maybe_auto_delete(X), Bindings}.


delete_forward_routes(Route) ->
    ok = mnesia:delete_object(rabbit_route, Route, write),
    ok = mnesia:delete_object(rabbit_durable_route, Route, write).

delete_transient_forward_routes(Route) ->
    ok = mnesia:delete_object(rabbit_route, Route, write).

contains(Table, MatchHead) ->
    continue(mnesia:select(Table, [{MatchHead, [], ['$_']}], 1, read)).

continue('$end_of_table')    -> false;
continue({[_|_], _})         -> true;
continue({[], Continuation}) -> continue(mnesia:select(Continuation)).

call_with_exchange(Exchange, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () -> case mnesia:read({rabbit_exchange, Exchange}) of
                   []  -> {error, not_found};
                   [X] -> Fun(X)
               end
      end).

call_with_exchange_and_queue(Exchange, Queue, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () -> case {mnesia:read({rabbit_exchange, Exchange}),
                     mnesia:read({rabbit_queue, Queue})} of
                   {[X], [Q]} -> Fun(X, Q);
                   {[ ], [_]} -> {error, exchange_not_found};
                   {[_], [ ]} -> {error, queue_not_found};
                   {[ ], [ ]} -> {error, exchange_and_queue_not_found}
               end
      end).

add_binding(ExchangeName, QueueName, RoutingKey, Arguments, InnerFun) ->
    case binding_action(
           ExchangeName, QueueName, RoutingKey, Arguments,
           fun (X, Q, B) ->
                   %% this argument is used to check queue exclusivity;
                   %% in general, we want to fail on that in preference to
                   %% anything else
                   case InnerFun(X, Q) of
                       ok ->
                           case mnesia:read({rabbit_route, B}) of
                               [] ->
                                   ok = sync_binding(B,
                                                     X#exchange.durable andalso
                                                     Q#amqqueue.durable,
                                                     fun mnesia:write/3),
                                   {new, X, B};
                               [_R] ->
                                   {existing, X, B}
                           end;
                       {error, _} = E ->
                           E
                   end
           end) of
        {new, Exchange = #exchange{ type = Type }, Binding} ->
            (type_to_module(Type)):add_binding(Exchange, Binding);
        {existing, _, _} ->
            ok;
        {error, _} = Err ->
            Err
    end.

delete_binding(ExchangeName, QueueName, RoutingKey, Arguments, InnerFun) ->
    case binding_action(
           ExchangeName, QueueName, RoutingKey, Arguments,
           fun (X, Q, B) ->
                   case mnesia:match_object(rabbit_route, #route{binding = B},
                                            write) of
                       [] ->
                           {error, binding_not_found};
                       _  ->
                           case InnerFun(X, Q) of
                               ok ->
                                   ok =
                                       sync_binding(B,
                                                    X#exchange.durable andalso
                                                    Q#amqqueue.durable,
                                                    fun mnesia:delete_object/3),
                                   {maybe_auto_delete(X), B};
                               {error, _} = E ->
                                   E
                           end
                   end
           end) of
        {error, _} = Err ->
            Err;
        {{IsDeleted, X = #exchange{ type = Type }}, B} ->
            Module = type_to_module(Type),
            case IsDeleted of
                auto_deleted -> Module:delete(X, [B]);
                not_deleted  -> Module:remove_bindings(X, [B])
            end
    end.

binding_action(ExchangeName, QueueName, RoutingKey, Arguments, Fun) ->
    call_with_exchange_and_queue(
      ExchangeName, QueueName,
      fun (X, Q) ->
              Fun(X, Q, #binding{
                       exchange_name = ExchangeName,
                       queue_name    = QueueName,
                       key           = RoutingKey,
                       args          = rabbit_misc:sort_field_table(Arguments)})
      end).

sync_binding(Binding, Durable, Fun) ->
    ok = case Durable of
             true  -> Fun(rabbit_durable_route,
                          #route{binding = Binding}, write);
             false -> ok
         end,
    {Route, ReverseRoute} = route_with_reverse(Binding),
    ok = Fun(rabbit_route, Route, write),
    ok = Fun(rabbit_reverse_route, ReverseRoute, write),
    ok.

list_bindings(VHostPath) ->
    [{ExchangeName, QueueName, RoutingKey, Arguments} ||
        #route{binding = #binding{
                 exchange_name = ExchangeName,
                 key           = RoutingKey,
                 queue_name    = QueueName,
                 args          = Arguments}}
            <- mnesia:dirty_match_object(
                 rabbit_route,
                 #route{binding = #binding{
                          exchange_name = rabbit_misc:r(VHostPath, exchange),
                          _             = '_'},
                        _       = '_'})].

route_with_reverse(#route{binding = Binding}) ->
    route_with_reverse(Binding);
route_with_reverse(Binding = #binding{}) ->
    Route = #route{binding = Binding},
    {Route, reverse_route(Route)}.

reverse_route(#route{binding = Binding}) ->
    #reverse_route{reverse_binding = reverse_binding(Binding)};

reverse_route(#reverse_route{reverse_binding = Binding}) ->
    #route{binding = reverse_binding(Binding)}.

reverse_binding(#reverse_binding{exchange_name = Exchange,
                                 queue_name    = Queue,
                                 key           = Key,
                                 args          = Args}) ->
    #binding{exchange_name = Exchange,
             queue_name    = Queue,
             key           = Key,
             args          = Args};

reverse_binding(#binding{exchange_name = Exchange,
                         queue_name    = Queue,
                         key           = Key,
                         args          = Args}) ->
    #reverse_binding{exchange_name = Exchange,
                     queue_name    = Queue,
                     key           = Key,
                     args          = Args}.

delete(ExchangeName, IfUnused) ->
    Fun = case IfUnused of
              true  -> fun conditional_delete/1;
              false -> fun unconditional_delete/1
          end,
    case call_with_exchange(ExchangeName, Fun) of
        {deleted, X = #exchange{type = Type}, Bs} ->
            (type_to_module(Type)):delete(X, Bs),
            ok;
        Error = {error, _InUseOrNotFound} ->
            Error
    end.

maybe_auto_delete(Exchange = #exchange{auto_delete = false}) ->
    {not_deleted, Exchange};
maybe_auto_delete(Exchange = #exchange{auto_delete = true}) ->
    case conditional_delete(Exchange) of
        {error, in_use}         -> {not_deleted, Exchange};
        {deleted, Exchange, []} -> {auto_deleted, Exchange}
    end.

conditional_delete(Exchange = #exchange{name = ExchangeName}) ->
    Match = #route{binding = #binding{exchange_name = ExchangeName, _ = '_'}},
    %% we need to check for durable routes here too in case a bunch of
    %% routes to durable queues have been removed temporarily as a
    %% result of a node failure
    case contains(rabbit_route, Match) orelse
         contains(rabbit_durable_route, Match) of
        false  -> unconditional_delete(Exchange);
        true   -> {error, in_use}
    end.

unconditional_delete(Exchange = #exchange{name = ExchangeName}) ->
    Bindings = delete_exchange_bindings(ExchangeName),
    ok = mnesia:delete({rabbit_durable_exchange, ExchangeName}),
    ok = mnesia:delete({rabbit_exchange, ExchangeName}),
    {deleted, Exchange, Bindings}.

%%----------------------------------------------------------------------------
%% EXTENDED API
%% These are API calls that are not used by the server internally,
%% they are exported for embedded clients to use

%% This is currently used in mod_rabbit.erl (XMPP) and expects this to
%% return {QueueName, RoutingKey, Arguments} tuples
list_exchange_bindings(ExchangeName) ->
    Route = #route{binding = #binding{exchange_name = ExchangeName,
                                      _ = '_'}},
    [{QueueName, RoutingKey, Arguments} ||
        #route{binding = #binding{queue_name = QueueName,
                                  key = RoutingKey,
                                  args = Arguments}}
            <- mnesia:dirty_match_object(rabbit_route, Route)].

% Refactoring is left as an exercise for the reader
list_queue_bindings(QueueName) ->
    Route = #route{binding = #binding{queue_name = QueueName,
                                      _ = '_'}},
    [{ExchangeName, RoutingKey, Arguments} ||
        #route{binding = #binding{exchange_name = ExchangeName,
                                  key = RoutingKey,
                                  args = Arguments}}
            <- mnesia:dirty_match_object(rabbit_route, Route)].

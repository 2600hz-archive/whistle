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

-module(rabbit_guid).

-behaviour(gen_server).

-export([start_link/0]).
-export([guid/0, string_guid/1, binstring_guid/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(SERIAL_FILENAME, "rabbit_serial").

-record(state, {serial}).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([guid/0]).

-type(guid() :: binary()).

-spec(start_link/0 :: () -> rabbit_types:ok_pid_or_error()).
-spec(guid/0 :: () -> guid()).
-spec(string_guid/1 :: (any()) -> string()).
-spec(binstring_guid/1 :: (any()) -> binary()).

-endif.

%%----------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE,
                          [update_disk_serial()], []).

update_disk_serial() ->
    Filename = filename:join(rabbit_mnesia:dir(), ?SERIAL_FILENAME),
    Serial = case rabbit_misc:read_term_file(Filename) of
                 {ok, [Num]}     -> Num;
                 {error, enoent} -> 0;
                 {error, Reason} ->
                     throw({error, {cannot_read_serial_file, Filename, Reason}})
             end,
    case rabbit_misc:write_term_file(Filename, [Serial + 1]) of
        ok -> ok;
        {error, Reason1} ->
            throw({error, {cannot_write_serial_file, Filename, Reason1}})
    end,
    Serial.

%% generate a GUID.
%%
%% The id is only unique within a single cluster and as long as the
%% serial store hasn't been deleted.
guid() ->
    %% We don't use erlang:now() here because a) it may return
    %% duplicates when the system clock has been rewound prior to a
    %% restart, or ids were generated at a high rate (which causes
    %% now() to move ahead of the system time), and b) it is really
    %% slow since it takes a global lock and makes a system call.
    %%
    %% A persisted serial number, in combination with self/0 (which
    %% includes the node name) uniquely identifies a process in space
    %% and time. We combine that with a process-local counter to give
    %% us a GUID.
    G = case get(guid) of
            undefined -> {{gen_server:call(?SERVER, serial, infinity), self()},
                          0};
            {S, I}   -> {S, I+1}
        end,
    put(guid, G),
    erlang:md5(term_to_binary(G)).

%% generate a readable string representation of a GUID.
string_guid(Prefix) ->
    Prefix ++ "-" ++ base64:encode_to_string(guid()).

binstring_guid(Prefix) ->
    list_to_binary(string_guid(Prefix)).

%%----------------------------------------------------------------------------

init([Serial]) ->
    {ok, #state{serial = Serial}}.

handle_call(serial, _From, State = #state{serial = Serial}) ->
    {reply, Serial, State};

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

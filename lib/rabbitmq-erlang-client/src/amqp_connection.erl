%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

%% @doc This module is responsible for maintaining a connection to an AMQP
%% broker and manages channels within the connection. This module is used to
%% open and close connections to the broker as well as creating new channels
%% within a connection.<br/>
%% The connections and channels created by this module are supervised under
%% amqp_client's supervision tree. Please note that connections and channels
%% do not get restarted automatically by the supervision tree in the case of a
%% failure. If you need robust connections and channels, we recommend you use
%% Erlang monitors on the returned connection and channel PID.
-module(amqp_connection).

-include("amqp_client.hrl").

-export([open_channel/1, open_channel/2]).
-export([start/1, start/2]).
-export([close/1, close/3]).
-export([info/2, info_keys/1, info_keys/0]).

%%---------------------------------------------------------------------------
%% Type Definitions
%%---------------------------------------------------------------------------

%% @type amqp_params() = #amqp_params{}.
%% As defined in amqp_client.hrl. It contains the following fields:
%% <ul>
%% <li>username :: binary() - The name of a user registered with the broker, 
%%     defaults to &lt;&lt;guest"&gt;&gt;</li>
%% <li>password :: binary() - The user's password, defaults to 
%%     &lt;&lt;"guest"&gt;&gt;</li>
%% <li>virtual_host :: binary() - The name of a virtual host in the broker,
%%     defaults to &lt;&lt;"/"&gt;&gt;</li>
%% <li>host :: string() - The hostname of the broker,
%%     defaults to "localhost" (network only)</li>
%% <li>port :: integer() - The port the broker is listening on,
%%     defaults to 5672 (network only)</li>
%% <li>node :: atom() - The node the broker runs on (direct only)</li>
%% <li>channel_max :: non_neg_integer() - The channel_max handshake parameter,
%%     defaults to 0</li>
%% <li>frame_max :: non_neg_integer() - The frame_max handshake parameter,
%%     defaults to 0 (network only)</li>
%% <li>heartbeat :: non_neg_integer() - The hearbeat interval in seconds,
%%     defaults to 0 (turned off) (network only)</li>
%% <li>ssl_options :: term() - The second parameter to be used with the
%%     ssl:connect/2 function, defaults to 'none' (network only)</li>
%% <li>client_properties :: [{binary(), atom(), binary()}] - A list of extra
%%     client properties to be sent to the server, defaults to []</li>
%% </ul>

%%---------------------------------------------------------------------------
%% Starting a connection
%%---------------------------------------------------------------------------

%% @spec (Type) -> {ok, Connection} | {error, Error}
%% where
%%     Type = network | direct
%%     Connection = pid()
%% @doc Starts a connection to an AMQP server. Use network type to connect
%% to a remote AMQP server - default connection settings are used, meaning that
%% the server is expected to be at localhost:5672, with a vhost of "/"
%% authorising a user guest/guest. Use direct type for a direct connection to
%% a RabbitMQ server, assuming that the server is running in the same process
%% space, and with a default set of amqp_params. If a different host, port,
%% vhost or credential set is required, start/2 should be used.
start(Type) ->
    start(Type, #amqp_params{}).

%% @spec (Type, amqp_params()) -> {ok, Connection} | {error, Error}
%% where
%%      Type = network | direct
%%      Connection = pid()
%% @doc Starts a connection to an AMQP server. Use network type to connect
%% to a remote AMQP server or direct type for a direct connection to
%% a RabbitMQ server, assuming that the server is running in the same process
%% space.
start(Type, AmqpParams) ->
    case amqp_client:start() of
        ok                                      -> ok;
        {error, {already_started, amqp_client}} -> ok;
        {error, _} = E                          -> throw(E)
    end,
    {ok, _Sup, Connection} =
        amqp_sup:start_connection_sup(
            Type, case Type of direct  -> amqp_direct_connection;
                               network -> amqp_network_connection
                  end, AmqpParams),
    amqp_gen_connection:connect(Connection).

%%---------------------------------------------------------------------------
%% Commands
%%---------------------------------------------------------------------------

%% @doc Invokes open_channel(ConnectionPid, none). 
%% Opens a channel without having to specify a channel number.
open_channel(ConnectionPid) ->
    open_channel(ConnectionPid, none).

%% @spec (ConnectionPid, ChannelNumber) -> {ok, ChannelPid} | {error, Error}
%% where
%%      ChannelNumber = pos_integer() | 'none'
%%      ConnectionPid = pid()
%%      ChannelPid = pid()
%% @doc Opens an AMQP channel.<br/>
%% This function assumes that an AMQP connection (networked or direct)
%% has already been successfully established.<br/>
%% ChannelNumber must be less than or equal to the negotiated max_channel value,
%% or less than or equal to ?MAX_CHANNEL_NUMBER if the negotiated max_channel
%% value is 0.<br/>
%% In the direct connection, max_channel is always 0.
open_channel(ConnectionPid, ChannelNumber) ->
    amqp_gen_connection:open_channel(ConnectionPid, ChannelNumber).

%% @spec (ConnectionPid) -> ok | Error
%% where
%%      ConnectionPid = pid()
%% @doc Closes the channel, invokes
%% close(Channel, 200, &lt;&lt;"Goodbye"&gt;&gt;).
close(ConnectionPid) ->
    close(ConnectionPid, 200, <<"Goodbye">>).

%% @spec (ConnectionPid, Code, Text) -> ok | closing
%% where
%%      ConnectionPid = pid()
%%      Code = integer()
%%      Text = binary()
%% @doc Closes the AMQP connection, allowing the caller to set the reply
%% code and text.
close(ConnectionPid, Code, Text) -> 
    Close = #'connection.close'{reply_text =  Text,
                                reply_code = Code,
                                class_id   = 0,
                                method_id  = 0},
    amqp_gen_connection:close(ConnectionPid, Close).

%%---------------------------------------------------------------------------
%% Other functions
%%---------------------------------------------------------------------------

%% @spec (ConnectionPid, Items) -> ResultList
%% where
%%      ConnectionPid = pid()
%%      Items = [Item]
%%      ResultList = [{Item, Result}]
%%      Item = atom()
%%      Result = term()
%% @doc Returns information about the connection, as specified by the Items
%% list. Item may be any atom returned by info_keys/1:
%%<ul>
%%<li>type - returns the type of the connection (network or direct)</li>
%%<li>server_properties - returns the server_properties fields sent by the
%%    server while establishing the connection</li>
%%<li>is_closing - returns true if the connection is in the process of closing
%%    and false otherwise</li>
%%<li>amqp_params - returns the #amqp_params{} structure used to start the
%%    connection</li>
%%<li>num_channels - returns the number of channels currently open under the
%%    connection (excluding channel 0)</li>
%%<li>channel_max - returns the channel_max value negotiated with the
%%    server</li>
%%<li>heartbeat - returns the heartbeat value negotiated with the server
%%    (only for the network connection)</li>
%%<li>frame_max - returns the frame_max value negotiated with the
%%    server (only for the network connection)</li>
%%<li>sock - returns the socket for the network connection (for use with
%%    e.g. inet:sockname/1) (only for the network connection)</li>
%%<li>any other value - throws an exception</li>
%%</ul>
info(ConnectionPid, Items) ->
    amqp_gen_connection:info(ConnectionPid, Items).

%% @spec (ConnectionPid) -> Items
%% where
%%      ConnectionPid = pid()
%%      Items = [Item]
%%      Item = atom()
%% @doc Returns a list of atoms that can be used in conjunction with info/2.
%% Note that the list differs from a type of connection to another (network vs.
%% direct). Use info_keys/0 to get a list of info keys that can be used for
%% any connection.
info_keys(ConnectionPid) ->
    amqp_gen_connection:info_keys(ConnectionPid).

%% @spec () -> Items
%% where
%%      Items = [Item]
%%      Item = atom()
%% @doc Returns a list of atoms that can be used in conjunction with info/2.
%% These are general info keys, which can be used in any type of connection.
%% Other info keys may exist for a specific type. To get the full list of
%% atoms that can be used for a certain connection, use info_keys/1.
info_keys() ->
    amqp_gen_connection:info_keys().

%% Copyright (c) 2016-2020, Gustaf Sjoberg <gsjoberg@gmail.com>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
-module(erlang_v8_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1]).

%% Supervisor callbacks

-export([init/1]).

-define(CHILD(I, Type, Args),
    {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%% API functions

start_link() ->
    start_link([]).
start_link(Env) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Env).

%% Supervisor callbacks

init(Env) ->
    Nodes = proplists:get_value(nodes, Env, []),

    SupFlags = #{strategy => one_for_all,
                 intensity => 1,
                 period => 10},

    ChildSpecs = [
        #{
            id => server_ref(ServerName),
            start => {erlang_v8_vm, start_link,
                [ServerName, maps:without([server_name], Node)]},
            restart => permanent,
            shutdown => 5000
        } || #{server_name := ServerName} = Node <- Nodes
    ],
    {ok, {SupFlags, ChildSpecs}}.

server_ref({local, LocalName}) when is_atom(LocalName) ->
    LocalName;
server_ref(ServerName) ->
    ServerName.
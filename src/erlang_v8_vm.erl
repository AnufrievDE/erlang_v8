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
-module(erlang_v8_vm).

-behaviour(gen_server).

-export([start/0]).
-export([start_link/1]).
-export([start_link/2]).
-export([start_link/3]).
-export([start_link/4]).
-export([stop/1]).

-export([reset/1]).
-export([restart/1]).

-export([create_context/1]).
-export([create_context/2]).
-export([destroy_context/2]).
-export([eval/3]).
-export([eval/4]).
-export([call/4]).
-export([call/5]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([handle_continue/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(EXECUTABLE, "erlang_v8").
-define(SPAWN_OPTS, [{packet, 4}, binary, exit_status]).
-define(DEFAULT_TIMEOUT, 2000).
-define(MAX_SOURCE_SIZE, 16#FFFFFFFF).

-define(OP_EVAL, 1).
-define(OP_CALL, 2).
-define(OP_CREATE_CONTEXT, 3).
-define(OP_DESTROY_CONTEXT, 4).
-define(OP_RESET_VM, 5).

-define(OP_OK, 0).
-define(OP_ERROR, 1).
-define(OP_TIMEOUT, 2).
-define(OP_INVALID_CONTEXT, 3).

-record(state, {
        initial_source = [],
        max_source_size = 5 * 1024 * 1024,
        port,
        table,
        monitor_pid
    }).

%% internal table record
-record(context, {
    ctx :: pos_integer(),
    name :: atom(),
    mref :: reference()
}).

%% External API

start_link(Args) ->
    start_link(undefined, Args).
start_link(Name, Args) ->
    start_link(Name, Args, []).
start_link(Name, Args, Opts) ->
    start_link(Name, ?MODULE, Args, Opts).
start_link(undefined, ?MODULE, Args, Opts) ->
    gen_server:start_link(?MODULE, Args, Opts);
start_link(Name, ?MODULE, Args, Opts) ->
    gen_server:start_link(Name, ?MODULE, Args, Opts).

start() ->
    gen_server:start(?MODULE, [], []).

create_context(ServerRef) ->
    create_context(ServerRef, undefined).
create_context(ServerRef, CtxName) ->
    call_with_timeout(ServerRef, {create_context, CtxName, 1000}, 5000).

eval(ServerRef, Ctx, Source) ->
    eval(ServerRef, Ctx, Source, ?DEFAULT_TIMEOUT).

eval(ServerRef, Ctx, Source, Timeout) ->
    call_with_timeout(ServerRef, {eval, Ctx, Source, Timeout}, 30000).

call(ServerRef, Ctx, FuncName, Args) ->
    call(ServerRef, Ctx, FuncName, Args, ?DEFAULT_TIMEOUT).

call(ServerRef, Ctx, FuncName, Args, Timeout) ->
    call_with_timeout(ServerRef, {call, Ctx, FuncName, Args, Timeout}, 30000).

destroy_context(ServerRef, Ctx) ->
    gen_server:call(ServerRef, {destroy_context, Ctx}, infinity).

reset(ServerRef) ->
    gen_server:call(ServerRef, reset).

restart(ServerRef) ->
    gen_server:call(ServerRef, restart).

stop(ServerRef) ->
    closed = gen_server:call(ServerRef, stop),
    ok.

%% Callbacks

init(NodeArgsMap) ->
    rand:seed(exs64),
    LegacyOpts = maps:get(options, NodeArgsMap, []),
    State = start_port(parse_opts(LegacyOpts)),

    ContextInitializers = maps:get(contexts, NodeArgsMap, []),
    %lazy_init_contexts(Contexts),
    {ok, State#state{table = create_table()},
        {continue, {create_init_contexts, ContextInitializers}}}.

handle_call({call, Ctx, FuncName, Args, Timeout}, _From, State) ->
    #state{table = Tab, port = Port, max_source_size = MaxSrcSize} = State,
    Instructions = jsx:encode(#{ function => FuncName,
                                 args => Args,
                                 timeout => Timeout }),
    Response =
        send_to_port(Port, ?OP_CALL, context(Tab, Ctx), Instructions, MaxSrcSize),
    handle_response(Response, State);

handle_call({eval, Ctx, Source, Timeout}, _From, State) ->
    #state{table = Tab, port = Port, max_source_size = MaxSrcSize} = State,
    Instructions = jsx:encode(#{ source => Source, timeout => Timeout }),
    Response = 
        send_to_port(Port, ?OP_EVAL, context(Tab, Ctx), Instructions, MaxSrcSize),
    handle_response(Response, State);

handle_call({create_context, CtxName, _Timeout}, {Pid, _Tag} = _From, State) ->
    #state{port = Port, table = Tab} = State,
    MRef = erlang:monitor(process, Pid),
    case do_create_context(CtxName, MRef, Tab, Port) of
        {ok, _Context} = OkRes ->
            {reply, OkRes, State};
        {error, crashed} = Error ->
            {stop, Error, State};
            %{reply, Error, start_port(kill_port(State))};
        OtherError ->
            {reply, OtherError, State}
    end;

handle_call({destroy_context, CtxOrCtxName}, _From,
            #state{port = Port, table = Tab} = State) ->
    Pattern =
        case CtxOrCtxName of
            C when is_atom(C) ->
                #context{name = C, _ = '_'};
            C when is_integer(C) ->
                #context{ctx = C, _ = '_'}
        end,
    {Result, NewState} =
    case ets:match_object(Tab, Pattern) of
        [#context{mref = MRef, ctx = Ctx}] ->
            true = ets:delete(Tab, Ctx),
            case MRef of
                undefined -> ok;
                _ -> erlang:demonitor(MRef, [flush])
            end,
            case send_to_port(Port, ?OP_DESTROY_CONTEXT, Ctx) of
                {ok, _Response} ->
                    {ok, State};
                {error, crashed} = Error ->
                    {stop, Error, State};
                    %{Error, start_port(kill_port(State))};
                _OtherError ->
                    {{error, invalid_context}, State}
            end;
        _ ->
            {{error, invalid_context}, State}
    end,
    {reply, Result, NewState};

handle_call(reset, _From, #state{port = Port} = State) ->
    Port ! {self(), {command, <<?OP_RESET_VM:8>>}},
    {reply, ok, State};

handle_call(restart, _From, State) ->
    {reply, ok, start_port(close_port(State))};

handle_call(stop, _From, State) ->
    {stop, normal, closed, State};

handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, _Pid, _Reason},
            #state{table = Tab, port = Port} = State) ->
    [#context{ctx = Ctx}] = 
        ets:match_object(Tab, #context{mref = MRef, _ = '_'}),
    true = ets:delete(Tab, Ctx),
    case send_to_port(Port, ?OP_DESTROY_CONTEXT, Ctx) of
        {error, crashed} = Error ->
            {stop, Error, State};
            %{noreply, start_port(kill_port(State))};
        _ ->
            {noreply, State}
    end;

handle_info(_Msg, State) ->
    {noreply, State}.

handle_continue({create_init_contexts, ContextInitializers}, State) ->
    #state{table = Tab, port = Port, max_source_size = MaxSrcSize} = State,
    Result = lists:foldl(
        fun(#{name := CtxName, eval := Eval}, {ok, _Response}) ->
            case do_create_context(CtxName, Tab, Port) of
                {ok, Ctx} ->
                    Instructions = jsx:encode(
                        #{source => Eval, timeout => ?DEFAULT_TIMEOUT}),
                    send_to_port(
                        Port, ?OP_EVAL, Ctx, Instructions, MaxSrcSize);
                Error -> Error
            end;
            (_, Error) -> Error
        end, {ok, boomer}, ContextInitializers),
    case Result of
        {error, _Reason} = Error ->
            {stop, {create_init_contexts, Error}, State};
        _ ->
            {noreply, State}
    end.

terminate(_Reason, State) ->
    close_port(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal API

handle_response({ok, Response}, State) ->
    {reply, {ok, Response}, State};
handle_response({error, invalid_source_size} = Error, State) ->
    {reply, Error, State};
handle_response({call_error, Reason}, State) ->
    {reply, {error, Reason}, State};
handle_response({error, crashed} = Error, State) ->
    {stop, Error, State};
handle_response({error, _Reason} = Error, State) ->
    {reply, Error, State}.
    %{reply, Error, start_port(kill_port(State))}.

%% @doc Close port gently.
close_port(#state{monitor_pid = Pid, port = Port} = State) ->
    catch port_close(Port),
    Pid ! demonitor,
    State#state{monitor_pid = undefined, port = undefined}.

%% @doc Close port and attempt to kill the OS process.
kill_port(#state{monitor_pid = Pid, port = Port} = State) ->
    catch port_close(Port),
    Pid ! kill,
    State#state{monitor_pid = undefined, port = undefined}.

create_table() ->
    ets:new(?MODULE,  [ordered_set, {keypos, 2}]). %named_table,

do_create_context(CtxName, Tab, Port) ->
    do_create_context(CtxName, undefined, Tab, Port).
do_create_context(CtxName, MRef, Tab, Port)
    when is_atom(CtxName) andalso (MRef =:= undefined orelse is_reference(MRef)) ->
    Ctx = erlang:unique_integer([positive]),
    case send_to_port(Port, ?OP_CREATE_CONTEXT, Ctx) of
        {ok, _Response} ->
            ets:insert(Tab, #context{ctx = Ctx, name = CtxName, mref = MRef}),
            {ok, Ctx};
        {error, crashed} = Error ->
            Error;
        _Other ->
            {error, invalid_context}
    end;
do_create_context(_, _, _, _) ->
    {error, invalid_input}.

context(Tab, CtxName) when is_atom(CtxName) ->
    MatchRes = ets:match_object(Tab, #context{name = CtxName, _ = '_'}),
    case MatchRes of
        [#context{ctx = Ctx}] -> Ctx;
        _ ->
            -1
    end;
context(_Table, Ctx) when is_integer(Ctx) ->
    Ctx.

%% @doc Start port and port monitor.
start_port(#state{initial_source = Source} = State) ->
    Executable = filename:join(priv_dir(), ?EXECUTABLE),
    Opts = [{args, [Source]}|?SPAWN_OPTS],
    Port = open_port({spawn_executable, Executable}, Opts),
    monitor_port(State#state{port = Port}).

%% @doc Kill active port monitor before starting a new process.
monitor_port(#state{monitor_pid = Pid} = State) when is_pid(Pid) ->
    Pid ! demonitor,
    monitor_port(State#state{monitor_pid = undefined});

%% @doc Start a process that monitors the port (and parent process) and kills
%% the actual OS process when things go south.
monitor_port(#state{port = Port} = State) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {os_pid, OSPid} = erlang:port_info(Port, os_pid),
        MRef = erlang:monitor(process, Parent),
        receive 
            demonitor ->
                erlang:demonitor(MRef);
            kill ->
                os_kill(OSPid);
            {'DOWN', _Ref, process, Parent, _Reason} ->
                os_kill(OSPid)
        end
    end),
    State#state{monitor_pid = Pid}.

%% @doc Kill OS process.
os_kill(OSPid) ->
    os:cmd(io_lib:format("kill -9 ~p", [OSPid])).

send_to_port(Port, Op, Ref) ->
    send_to_port(Port, Op, Ref, <<>>).

send_to_port(Port, Op, Ref, Data) ->
    send_to_port(Port, Op, Ref, Data, infinity).

%% @doc Send source to port and wait for response
send_to_port(_Port, _Op, _Ref, Data, MaxSrcSize)
  when size(Data) > MaxSrcSize ->
    {error, invalid_source_size};
send_to_port(Port, Op, Ref, Data, _MaxSourceSize) ->
    Port ! {self(), {command, <<Op:8, Ref:32, Data/binary>>}},
    receive_port_data(Port).

receive_port_data(Port) ->
    receive
        {Port, {data, <<_:8, _Ref:32, "">>}} ->
            {ok, undefined};
        {Port, {data, <<?OP_OK:8, _Ref:32, "undefined">>}} ->
            {ok, undefined};
        {Port, {data, <<?OP_OK:8, _Ref:32, Response/binary>>}} ->
            case catch jsx:decode(Response, [return_maps]) of 
                {'EXIT', _F} ->
                    {ok, Response};
                R ->
                    {ok, R}
            end;
        {Port, {data, <<?OP_ERROR:8, _Ref:32, Response/binary>>}} ->
            #{ <<"error">> := Reason } = jsx:decode(Response, [return_maps]),
            {call_error, Reason};
        {Port, {data, <<?OP_TIMEOUT:8, _Ref:32, _/binary>>}} ->
            {call_error, timeout};
        {Port, {data, <<?OP_INVALID_CONTEXT:8, _Ref:32, _/binary>>}} ->
            {call_error, invalid_context};
        {Port, {exit_status, _Status}} ->
            {error, crashed};
        {Port, Error} ->
            %% TODO: we should probably special case here.
            {error, Error}
    end.

%% @doc Return the path to the application's priv dir (assuming directory
%% structure is intact).
priv_dir() ->
    filename:join(filename:dirname(filename:dirname(code:which(?MODULE))),
                  "priv").

%% @doc Parse proplists/opts and populate a state record.
parse_opts(Opts) ->
    lists:foldl(fun parse_opt/2, #state{initial_source = <<>>}, Opts).

%% @doc Append source specified in source option.
parse_opt({source, S}, #state{initial_source = InitialSource} = State) ->
    State#state{initial_source = <<InitialSource/binary, S/binary>>};

%% @doc Read contents of file option and append to state.
parse_opt({file, F}, #state{initial_source = InitialSource} = State) ->
    %% Files should probably be read in the OS process instead to prevent
    %% keeping multiple copies of the JS source code in memory.
    {ok, S} = file:read_file(F),
    State#state{initial_source = <<InitialSource/binary, S/binary>>};

%% @doc Invalid max source size
parse_opt({max_source_size, N}, _State) when N > ?MAX_SOURCE_SIZE ->
    error(invalid_max_source_size_value);

%% @doc Set max source size for this vm
parse_opt({max_source_size, N}, State) ->
    State#state{max_source_size = N};

%% @doc Ignore unknown options.
parse_opt(_, State) -> State.

call_with_timeout(Pid, Message, Timeout) ->
    try
        gen_server:call(Pid, Message, Timeout)
    catch exit:{timeout, _Context} ->
        {error, vm_unresponsive}
    end.

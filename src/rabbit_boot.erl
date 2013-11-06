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
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_boot).

-export([boot_with/1, shutdown/1]).
-export([start/1, stop/1]).
-export([run_boot_steps/1]).
-export([boot_error/2, boot_error/4]).

-ifdef(use_specs).

-spec(boot_with/1      :: (fun(() -> 'ok')) -> 'ok').
-spec(shutdown/1       :: ([atom()]) -> 'ok').
-spec(start/1          :: ([atom()]) -> 'ok').
-spec(stop/1           :: ([atom()]) -> 'ok').
-spec(run_boot_steps/1 :: (atom())   -> 'ok').
-spec(boot_error/2     :: (term(), not_available | [tuple()]) -> no_return()).
-spec(boot_error/4     :: (term(), string(), [any()], not_available | [tuple()])
                          -> no_return()).

-endif.

-define(BOOT_FILE, "boot.info").

%%---------------------------------------------------------------------------
%% Public API

boot_with(StartFun) ->
    %% TODO: this should be done with monitors, not links, I think
    Marker = spawn_link(fun() -> receive stop -> ok end end),
    register(rabbit_boot, Marker),
    try
        StartFun()
    catch
        throw:{could_not_start, _App, _Reason}=Err ->
            boot_error(Err, not_available);
        _:Reason ->
            boot_error(Reason, erlang:get_stacktrace())
    after
        unlink(Marker),
        Marker ! stop,
        %% give the error loggers some time to catch up
        timer:sleep(100)
    end.

shutdown(Apps) ->
    try
        case whereis(rabbit_boot) of
            undefined -> ok;
            _         -> await_startup(Apps)
        end,
        rabbit_log:info("Stopping RabbitMQ~n"),
        ok = app_utils:stop_applications(Apps)
    after
        delete_boot_table()
    end.

start(Apps) ->
    try
        ensure_boot_table(),
        ok = app_utils:load_applications(Apps),
        StartupApps = app_utils:app_dependency_order(Apps, false),
        ok = app_utils:start_applications(StartupApps,
                                          handle_app_error(could_not_start))
    after
        save_boot_table()
    end.

stop(Apps) ->
    ensure_boot_table(),
    ShutdownApps = app_utils:app_dependency_order(Apps, true),
    try
        ok = app_utils:stop_applications(
               ShutdownApps, handle_app_error(error_during_shutdown))
    after
        [run_steps(App, rabbit_cleanup_step) || App <- ShutdownApps]
        %[begin
        %     Steps =
        %         sort_boot_steps(rabbit_misc:all_module_attributes(
        %                           App, rabbit_cleanup_step)),
        %     [run_boot_step(Step) || Step <- Steps]
        % end || App <- ShutdownApps]
    end.

run_boot_steps(App) ->
    run_steps(App, rabbit_boot_step).

run_steps(App, StepType) ->
    RootApps = app_utils:app_dependencies(App),
    Steps =
        sort_boot_steps(
          lists:usort(
            lists:append(
              [rabbit_misc:all_module_attributes(A, StepType) ||
                  A <- [App|RootApps]]))),
    [ok = run_boot_step(Step, StepType) || Step <- Steps],
    ok.

boot_error(Term={error, {timeout_waiting_for_tables, _}}, _Stacktrace) ->
    AllNodes = rabbit_mnesia:cluster_nodes(all),
    {Err, Nodes} =
        case AllNodes -- [node()] of
            [] -> {"Timeout contacting cluster nodes. Since RabbitMQ was"
                   " shut down forcefully~nit cannot determine which nodes"
                   " are timing out.~n", []};
            Ns -> {rabbit_misc:format(
                     "Timeout contacting cluster nodes: ~p.~n", [Ns]),
                   Ns}
        end,
    basic_boot_error(Term,
                     Err ++ rabbit_nodes:diagnostics(Nodes) ++ "~n~n", []);
boot_error(Reason, Stacktrace) ->
    Fmt = "Error description:~n   ~p~n~n" ++
        "Log files (may contain more information):~n   ~s~n   ~s~n~n",
    Args = [Reason, log_location(kernel), log_location(sasl)],
    boot_error(Reason, Fmt, Args, Stacktrace).

boot_error(Reason, Fmt, Args, not_available) ->
    basic_boot_error(Reason, Fmt, Args);
boot_error(Reason, Fmt, Args, Stacktrace) ->
    basic_boot_error(Reason, Fmt ++ "Stack trace:~n   ~p~n~n",
                     Args ++ [Stacktrace]).

%%---------------------------------------------------------------------------
%% Private API

await_startup(Apps) ->
    app_utils:wait_for_applications(Apps).

delete_boot_table() ->
    case filelib:is_file(boot_file()) of
        true  -> file:delete(boot_file());
        false -> ok
    end.

ensure_boot_table() ->
    case whereis(?MODULE) of
        undefined ->
            case filelib:is_file(boot_file()) of
                true  -> load_table();
                false -> clean_table()
            end;
        _Pid ->
            clean_table()
    end.

clean_table() ->
    ets:new(?MODULE, [named_table, public, ordered_set]).

load_table() ->
    {ok, _Tab} = ets:file2tab(boot_file(), [{verify, true}]),
    ok.

save_boot_table() ->
    delete_boot_table(),
    case ets:info(?MODULE) of
        undefined -> ok;
        _         -> ets:tab2file(?MODULE, boot_file(),
                                  [{extended_info, [object_count]}]),
                     ets:delete(?MODULE)
    end.

boot_file() ->
    filename:join(rabbit_mnesia:dir(), ?BOOT_FILE).

handle_app_error(Term) ->
    fun(App, {bad_return, {_MFA, {'EXIT', {ExitReason, _}}}}) ->
            throw({Term, App, ExitReason});
       (App, Reason) ->
            throw({Term, App, Reason})
    end.

run_boot_step({StepName, Attributes}, StepType) ->
    case catch {StepType, already_run(StepName)} of
        {rabbit_clean_step, _} -> run_it(StepName, Attributes);
        {_, false}             -> run_it(StepName, Attributes);
        {_, true}              -> ok
    end.

run_it(StepName, Attributes) ->
    case [MFA || {mfa, MFA} <- Attributes] of
        [] ->
            ok;
        MFAs ->
            [try
                 apply(M,F,A)
             of
                 ok              -> mark_complete(StepName);
                 {error, Reason} -> boot_error(Reason, not_available)
             catch
                 _:Reason -> boot_error(Reason, erlang:get_stacktrace())
             end || {M,F,A} <- MFAs],
            ok
    end.

already_run(StepName) ->
    ets:member(?MODULE, StepName).

mark_complete(StepName) ->
    ets:insert(?MODULE, {StepName}).

basic_boot_error(Reason, Format, Args) ->
    io:format("~n~nBOOT FAILED~n===========~n~n" ++ Format, Args),
    rabbit_misc:local_info_msg(Format, Args),
    timer:sleep(1000),
    exit({?MODULE, failure_during_boot, Reason}).

%% TODO: move me to rabbit_misc
log_location(Type) ->
    case application:get_env(rabbit, case Type of
                                         kernel -> error_logger;
                                         sasl   -> sasl_error_logger
                                     end) of
        {ok, {file, File}} -> File;
        {ok, false}        -> undefined;
        {ok, tty}          -> tty;
        {ok, silent}       -> undefined;
        {ok, Bad}          -> throw({error, {cannot_log_to_file, Bad}});
        _                  -> undefined
    end.

vertices(_Module, Steps) ->
    [{StepName, {StepName, Atts}} || {StepName, Atts} <- Steps].

edges(_Module, Steps) ->
    [case Key of
         requires -> {StepName, OtherStep};
         enables  -> {OtherStep, StepName}
     end || {StepName, Atts} <- Steps,
            {Key, OtherStep} <- Atts,
            Key =:= requires orelse Key =:= enables].

sort_boot_steps(UnsortedSteps) ->
    case rabbit_misc:build_acyclic_graph(fun vertices/2, fun edges/2,
                                         UnsortedSteps) of
        {ok, G} ->
            %% Use topological sort to find a consistent ordering (if
            %% there is one, otherwise fail).
            SortedSteps = lists:reverse(
                            [begin
                                 {StepName, Step} = digraph:vertex(G,
                                                                   StepName),
                                 Step
                             end || StepName <- digraph_utils:topsort(G)]),
            digraph:delete(G),
            %% Check that all mentioned {M,F,A} triples are exported.
            case [{StepName, {M,F,A}} ||
                     {StepName, Attributes} <- SortedSteps,
                     {mfa, {M,F,A}}         <- Attributes,
                     not erlang:function_exported(M, F, length(A))] of
                []               -> SortedSteps;
                MissingFunctions -> basic_boot_error(
                                      {missing_functions, MissingFunctions},
                                      "Boot step functions not exported: ~p~n",
                                      [MissingFunctions])
            end;
        {error, {vertex, duplicate, StepName}} ->
            basic_boot_error({duplicate_boot_step, StepName},
                             "Duplicate boot step name: ~w~n", [StepName]);
        {error, {edge, Reason, From, To}} ->
            basic_boot_error(
              {invalid_boot_step_dependency, From, To},
              "Could not add boot step dependency of ~w on ~w:~n~s",
              [To, From,
               case Reason of
                   {bad_vertex, V} ->
                       io_lib:format("Boot step not registered: ~w~n", [V]);
                   {bad_edge, [First | Rest]} ->
                       [io_lib:format("Cyclic dependency: ~w", [First]),
                        [io_lib:format(" depends on ~w", [Next]) ||
                            Next <- Rest],
                        io_lib:format(" depends on ~w~n", [First])]
               end])
    end.


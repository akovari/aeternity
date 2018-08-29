%%% -*- erlang-indent-level: 4 -*-
%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc Main conductor of the mining
%%%
%% The aec_conductor is the main hub of the mining engine.
%%%
%%% The mining has two states of operation 'running' and 'stopped' Passing the
%%% option {autostart, bool()} to the initialization controls which mode to
%%% start in. In the running mode, block candidates are generated by
%%% `aec_block_generator' and mined in a separate worker. When mining is
%%% successful, the mined block is published and added to the chain if the
%%% state of the chain allows that. In the stopped mode only blocks arriving
%%% from other miners are added to the chain.
%%%
%%% The mining can be controlled by the API functions start_mining/0
%%% and stop_mining/0. The stop_mining is preemptive (i.e., all workers
%%% involved in mining are killed).
%%%
%%% The aec_conductor operates by delegating all heavy operations to
%%% worker processes in order to be responsive. (See doc at the worker
%%% handling section.)
%%%
%%% The work flow in mining is divided into stages:
%%%  - wait for keys (of the miner)
%%%  - wait for block candidate generation
%%%  - start mining
%%%  - retry mining
%%%
%%% The principle is to optimistically try to start mining, and fall
%%% back to an earlier stage if the preconditions are not met. The next
%%% stage of mining should be triggered in the worker reply for each
%%% stage based on the postconditions of that stage.
%%%
%%% E.g. If the start_mining stage is attempted without having a block
%%% candidate, it should fall back to wait for a block candidate.
%%%
%%% E.g. When the mining worker returns it should either start mining a
%%% new block or retry mining based on the return of the mining.
%%% @end
%%% --------------------------------------------------------------------

-module(aec_conductor).

-behaviour(gen_server).

%% Mining API
-export([ get_mining_state/0
        , get_mining_workers/0
        , start_mining/0
        , stop_mining/0
        , handoff_leader/0
        ]).

%% Chain API
-export([ add_synced_block/1
        , get_key_block_candidate/0
        , post_block/1
        ]).

%% for tests
-export([reinit_chain/0
        ]).

%% gen_server API
-export([ start_link/0
        , start_link/1
        , stop/0 %% For testing
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-export_type([options/0]).

-include("blocks.hrl").
-include("aec_conductor.hrl").

-define(SERVER, ?MODULE).

-define(DEFAULT_MINING_ATTEMPT_TIMEOUT, 60 * 60 * 1000). %% milliseconds

%%%===================================================================
%%% API
%%%===================================================================

%%%===================================================================
%%% Gen server API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

stop() ->
    gen_server:stop(?SERVER).

%%%===================================================================
%%% Mining API

-spec start_mining() -> 'ok'.
start_mining() ->
    gen_server:call(?SERVER, start_mining).

-spec stop_mining() -> 'ok'.
stop_mining() ->
    gen_server:call(?SERVER, stop_mining).

-spec get_mining_state() -> mining_state().
get_mining_state() ->
    gen_server:call(?SERVER, get_mining_state).

-spec get_mining_workers() -> [pid()].
get_mining_workers() ->
    gen_server:call(?SERVER, get_mining_workers).

-spec handoff_leader() -> 'ok'.
handoff_leader() ->
    gen_server:call(?SERVER, handoff_leader).

%%%===================================================================
%%% Chain API

-spec post_block(aec_blocks:block()) -> 'ok' | {'error', any()}.
post_block(Block) ->
    aec_blocks:assert_block(Block),
    gen_server:call(?SERVER, {post_block, Block}).

-spec add_synced_block(map()) -> 'ok' | {'error', any()}.
add_synced_block(Block) ->
    gen_server:call(?SERVER, {add_synced_block, Block}).

-spec get_key_block_candidate() -> {'ok', aec_blocks:block()} | {'error', atom()}.
get_key_block_candidate() ->
    gen_server:call(?SERVER, get_key_block_candidate).

-spec reinit_chain() -> aec_headers:header().
reinit_chain() ->
    gen_server:call(?SERVER, reinit_chain).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Options) ->
    process_flag(trap_exit, true),
    ok     = init_chain_state(),
    TopBlockHash = aec_chain:top_block_hash(),
    TopKeyBlockHash = aec_chain:top_key_block_hash(),
    Consensus = #consensus{micro_block_cycle = aec_governance:micro_block_cycle(),
                           leader = false},
    {ok, Beneficiary} = get_beneficiary(),
    State1 = #state{ top_block_hash = TopBlockHash,
                     top_key_block_hash = TopKeyBlockHash,
                     consensus = Consensus,
                     beneficiary = Beneficiary},
    State2 = set_option(autostart, Options, State1),

    aec_metrics:try_update([ae,epoch,aecore,chain,height],
                            aec_blocks:height(aec_chain:top_block())),
    epoch_mining:info("Miner process initilized ~p", [State2]),
    aec_events:subscribe(candidate_block),
    %% NOTE: The init continues at handle_info(init_continue, State).
    self() ! init_continue,
    {ok, State2}.

init_chain_state() ->
    case aec_chain:genesis_hash() of
        undefined ->
            {GB, _GBState} = aec_block_genesis:genesis_block_with_state(),
            ok = aec_chain_state:insert_block(GB);
        Hash when is_binary(Hash) ->
            ok
    end.

reinit_chain_state() ->
    %% NOTE: ONLY FOR TEST
    aec_db:transaction(fun() ->
                               aec_db:clear_db(),
                               init_chain_state()
                       end),
    exit(whereis(aec_tx_pool), kill),
    ok.

handle_call({add_synced_block, Block},_From, State) ->
    {Reply, State1} = handle_synced_block(Block, State),
    {reply, Reply, State1};
handle_call(get_key_block_candidate,_From, State) ->
    Res =
        case State#state.key_block_candidate of
            undefined when State#state.mining_state =:= stopped ->
                {error, not_mining};
            undefined when State#state.mining_state =:= running ->
                {error, miner_starting};
            #candidate{block=Block} ->
                {ok, Block}
        end,
    {reply, Res, State};
handle_call({post_block, Block},_From, State) ->
    {Reply, State1} = handle_post_block(Block, State),
    {reply, Reply, State1};
handle_call(stop_mining,_From, State = #state{ consensus = Cons }) ->
    epoch_mining:info("Mining stopped"),
    [ aec_tx_pool:garbage_collect() || is_record(Cons, consensus) andalso Cons#consensus.leader ],
    State1 = kill_all_workers(State),
    {reply, ok, State1#state{mining_state = 'stopped',
                             key_block_candidate = undefined}};
handle_call(start_mining,_From, #state{mining_state = 'running'} = State) ->
    epoch_mining:info("Mining running"),
    {reply, ok, State};
handle_call(start_mining,_From, State = #state{ consensus = Cons }) ->
    epoch_mining:info("Mining started"),
    State1 = start_mining(State#state{mining_state = 'running', consensus = Cons#consensus{leader = false}}),
    {reply, ok, State1};
handle_call(get_mining_state,_From, State) ->
    {reply, State#state.mining_state, State};
handle_call(get_mining_workers, _From, State) ->
    {reply, worker_pids_by_tag(mining, State), State};
handle_call(reinit_chain, _From, State1 = #state{ consensus = Cons }) ->
    %% NOTE: ONLY FOR TEST
    ok = reinit_chain_state(),
    TopBlockHash = aec_chain:top_block_hash(),
    TopKeyBlockHash = aec_chain:top_key_block_hash(),
    State2 = State1#state{top_block_hash = TopBlockHash,
                          top_key_block_hash = TopKeyBlockHash},
    State =
        case State2#state.mining_state of
            stopped  ->
                State2;
            running ->
                epoch_mining:info("Mining stopped"),
                State3 = kill_all_workers(State2),
                hard_reset_block_generator(),
                epoch_mining:info("Mining started"),
                start_mining(State3#state{mining_state = running,
                                          micro_block_candidate = undefined,
                                          key_block_candidate = undefined,
                                          consensus = Cons#consensus{leader = false}})
        end,
    {reply, ok, State};
handle_call(Request, _From, State) ->
    epoch_mining:error("Received unknown request: ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(Other, State) ->
    epoch_mining:error("Received unknown cast: ~p", [Other]),
    {noreply, State}.

handle_info({gproc_ps_event, candidate_block, _}, State = #state{consensus = #consensus{leader = false}}) ->
    %% ignore new candidates if we are not a leader any more.
    {noreply, State};
handle_info({gproc_ps_event, candidate_block, #{info := new_candidate}}, State) ->
    case try_fetch_and_make_candidate() of
        {ok, Candidate} ->
            State1 = State#state{ micro_block_candidate = Candidate },
            {noreply, start_micro_signing(State1)};
        {error, no_candidate} ->
            {noreply, State#state{ micro_block_candidate = undefined }}
    end;
handle_info(init_continue, State) ->
    {noreply, start_mining(State)};
handle_info({worker_reply, Pid, Res}, State) ->
    State1 = handle_worker_reply(Pid, Res, State),
    {noreply, State1};
handle_info({'DOWN', Ref, process, Pid, Why}, State) when Why =/= normal->
    State1 = handle_monitor_message(Ref, Pid, Why, State),
    {noreply, State1};
handle_info(Other, State) ->
    %% TODO: Handle monitoring messages
    epoch_mining:error("Received unknown info message: ~p", [Other]),
    {noreply, State}.

terminate(_Reason, State) ->
    kill_all_workers(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_beneficiary() ->
    case aeu_env:user_config_or_env([<<"mining">>, <<"beneficiary">>], aecore, beneficiary) of
        {ok, EncodedBeneficiary} ->
            case aec_base58c:safe_decode(account_pubkey, EncodedBeneficiary) of
                {ok, _Beneficiary} = Result ->
                    Result;
                {error, Reason} ->
                    {error, {beneficiary_error, Reason}}
            end;
        undefined ->
            {error, beneficiary_not_configured}
    end.

try_fetch_and_make_candidate() ->
    case aec_block_generator:get_candidate() of
        {ok, Block} ->
            Candidate = make_micro_candidate(Block),
            {ok, Candidate};
        {error, no_candidate} = Err ->
            Err
    end.

make_key_candidate(Block) ->
    HeaderBin = aec_headers:serialize_to_binary(aec_blocks:to_header(Block)),
    LastNonce = aec_pow:pick_nonce(),
    Nonce     = aec_pow:next_nonce(LastNonce),
    #candidate{ block = Block,
                bin = HeaderBin,
                nonce = Nonce,
                max_nonce = LastNonce,
                top_hash = aec_blocks:prev_hash(Block) }.

make_micro_candidate(Block) ->
    HeaderBin = aec_headers:serialize_to_binary(aec_blocks:to_header(Block)),
    #candidate{ block = Block,
                bin = HeaderBin,
                top_hash = aec_blocks:prev_hash(Block) }.

%%%===================================================================
%%% Handle init options

set_option(autostart, Options, State) ->
    case get_option(autostart, Options) of
        undefined   -> State;
        {ok, true}  -> State#state{mining_state = running};
        {ok, false} -> State#state{mining_state = stopped}
    end.

get_option(Opt, Options) ->
    case proplists:lookup(Opt, Options) of
        none -> application:get_env(aecore, Opt);
        {_, Val} -> {ok, Val}
    end.

%%%===================================================================
%%% Handle monitor messages

handle_monitor_message(Ref, Pid, Why, State) ->
    Workers = State#state.workers,
    Blocked = State#state.blocked_tags,
    case lookup_worker(Ref, Pid, State) of
        not_found ->
            epoch_mining:info("Got unknown monitor DOWN message: ~p",
                              [{Ref, Pid, Why}]),
            State;
        {ok, Tag} ->
            epoch_mining:error("Worker died: ~p", [{Tag, Pid, Why}]),
            State1 = State#state{workers = orddict:erase(Pid, Workers),
                                 blocked_tags = ordsets:del_element(Tag, Blocked)
                                },
            start_mining(State1)
    end.

%%%===================================================================
%%% Worker handling
%%% @private
%%% @doc
%%%
%%% Worker functions are funs of arity 0 with a tag to determine the
%%% type of worker. Tags are enforced to be 'singleton' (only one worker
%%% allowed) or 'concurrent' (allow concurrent processes).
%%%
%%% The worker processes are monitored. Some types of worker are
%%% killed after a timeout.
%%%
%%% The worker processes provide return values through message
%%% passing. Return values are passed as messages, and the reply is
%%% handled based on the tag. The worker fun does not need to handle
%%% the message passing itself. This is taken care of by the
%%% dispatcher.
%%%
%%% Note that when the reply is handled, the state is the current
%%% server state, not the state in which the worker was
%%% dispatched. Any consistency checks for staleness must be handled
%%% in the reply handler.
%%%
%%% Workers can be killed (e.g., on preemption because of a changed
%%% chain) based on tag. Note that since the worker might have sent an
%%% answer before it is killed, it is good to check answers for
%%% staleness. TODO: This could be done by the framework.

lookup_worker(Ref, Pid, State) ->
    case orddict:find(Pid, State#state.workers) of
        {ok, #worker_info{mon = Ref} = Info} -> {ok, Info#worker_info.tag};
        error -> not_found
    end.

worker_pids_by_tag(Tag, State) ->
    orddict:fetch_keys(
      orddict:filter(
        fun(_, Info) -> Info#worker_info.tag == Tag end,
        State#state.workers)).

dispatch_worker(Tag, Fun, State) ->
    case is_tag_blocked(Tag, State) of
        true ->
            epoch_mining:error("Disallowing dispatch of additional ~p worker",
                               [Tag]),
            State;
        false ->
            {Pid, Info} = spawn_worker(Tag, Fun),
            State1 = block_tag(Tag, State),
            Workers = orddict:store(Pid, Info, State1#state.workers),
            State1#state{workers = Workers}
    end.

is_tag_blocked(Tag, State) ->
    ordsets:is_element(Tag, State#state.blocked_tags).

block_tag(Tag, #state{blocked_tags = B} = State) ->
    State#state{blocked_tags = ordsets:add_element(Tag, B)}.

spawn_worker(Tag, Fun) ->
    Timeout = worker_timeout(Tag),
    spawn_worker(Tag, Fun, Timeout).

worker_timeout(create_key_block_candidate) ->
    infinity;
worker_timeout(micro_sleep) ->
    infinity; %% TODO NG: pull from governance and add buffer
worker_timeout(mining) ->
    aeu_env:get_env(aecore, mining_attempt_timeout, ?DEFAULT_MINING_ATTEMPT_TIMEOUT);
worker_timeout(wait_for_keys) ->
    infinity.

spawn_worker(Tag, Fun, Timeout) ->
    Wrapper = wrap_worker_fun(Fun),
    {Pid, Ref} = spawn_monitor(Wrapper),
    Timer = case Timeout of
                infinity ->
                    no_timer;
                TimeMs when is_integer(TimeMs), TimeMs > 0 ->
                    {ok, TRef} = timer:exit_after(TimeMs, Pid, shutdown),
                    {t, TRef}
            end,
    {Pid, #worker_info{tag = Tag, mon = Ref, timer = Timer}}.

wrap_worker_fun(Fun) ->
    Server = self(),
    fun() ->
            Server ! {worker_reply, self(), Fun()}
    end.

handle_worker_reply(Pid, Reply, State) ->
    Workers = State#state.workers,
    Blocked = State#state.blocked_tags,
    case orddict:find(Pid, Workers) of
        {ok, Info} ->
            cleanup_after_worker(Info),
            Tag = Info#worker_info.tag,
            State1 = State#state{workers = orddict:erase(Pid, Workers),
                                 blocked_tags = ordsets:del_element(Tag, Blocked)
                                },
            worker_reply(Tag, Reply, State1);
        error ->
            epoch_mining:info("Got unsolicited worker reply: ~p",
                               [{Pid, Reply}]),
            State
    end.


worker_reply(create_key_block_candidate, Res, State) ->
    handle_key_block_candidate_reply(Res, State);
worker_reply(mining, Res, State) ->
    handle_mining_reply(Res, State);
worker_reply(micro_sleep, Res, State) ->
    handle_micro_sleep_reply(Res, State);
worker_reply(wait_for_keys, Res, State) ->
    handle_wait_for_keys_reply(Res, State).

%%%===================================================================
%%% Preemption of workers if the top of the chain changes.

preempt_if_new_top(#state{ top_block_hash = OldHash,
                           top_key_block_hash = OldKeyHash } = State, Origin) ->
    case aec_chain:top_block_hash() of
        OldHash -> no_change;
        NewHash ->
            ok = aec_tx_pool:top_change(OldHash, NewHash),

            aec_events:publish(top_changed, NewHash),
            {ok, NewBlock} = aec_chain:get_block(NewHash),
            maybe_publish_top(Origin, NewBlock),
            aec_metrics:try_update([ae,epoch,aecore,chain,height],
                                   aec_blocks:height(NewBlock)),
            State1 = State#state{top_block_hash = NewHash},
            {ok, KeyHash} = aec_chain:get_key_hash(NewHash),
            %% A new micro block from the same generation should
            %% not cause a pre-emption or full re-generation of key-block.
            case aec_blocks:type(NewBlock) of
                micro when OldKeyHash =:= KeyHash ->
                    {micro_changed, State1};
                KeyOrNewForkMicro ->
                    State2 = kill_all_workers_with_tag(mining, State1),
                    State3 = kill_all_workers_with_tag(create_key_block_candidate, State2),
                    State4 = kill_all_workers_with_tag(micro_sleep, State3), %% in case we are the leader
                    NewTopKey = case KeyOrNewForkMicro of
                                    micro -> KeyHash;
                                    key   -> NewHash
                                end,
                    State5 = State4#state{ top_key_block_hash = NewTopKey,
                                           key_block_candidate = undefined },
                    {changed, NewBlock, State5}
            end
    end.


maybe_publish_top(block_created,_TopBlock) ->
    %% A new block we created is published unconditionally below.
    ok;
maybe_publish_top(micro_block_created,_TopBlock) ->
    %% A new block we created is published unconditionally below.
    ok;
maybe_publish_top(block_synced,_TopBlock) ->
    %% We don't publish blocks pulled from network. Otherwise on
    %% bootstrap the node would publish old blocks.
    ok;
maybe_publish_top(block_received, TopBlock) ->
    %% The received block pushed by a network peer changed the
    %% top. Publish the new top.
    aec_events:publish(block_to_publish, TopBlock);
maybe_publish_top(micro_block_received, TopBlock) ->
    %% The received micro block pushed by a network peer changed the
    %% top. Publish the new top.
    aec_events:publish(block_to_publish, TopBlock).


maybe_publish_block(block_synced,_Block) ->
    %% We don't publish blocks pulled from network. Otherwise on
    %% bootstrap the node would publish old blocks.
    ok;
maybe_publish_block(BlockReceived,_Block)
  when BlockReceived =:= block_received
    orelse BlockReceived =:= micro_block_received ->
    %% We don't publish all blocks pushed by network peers, only if it
    %% changes the top.
    ok;
maybe_publish_block(block_created = T, Block) ->
    aec_events:publish(T, Block),
    %% This is a block we created ourselves. Always publish.
    aec_events:publish(block_to_publish, Block);

maybe_publish_block(micro_block_created = T, Block) ->
    aec_events:publish(T, Block),
    %% This is a block we created ourselves. Always publish.
    aec_events:publish(block_to_publish, Block).



cleanup_after_worker(Info) ->
    case Info#worker_info.timer of
        no_timer -> ok;
        {t, TRef} -> timer:cancel(TRef)
    end,
    demonitor(Info#worker_info.mon, [flush]),
    ok.

kill_worker(Pid, Info, State) ->
    Workers = State#state.workers,
    Blocked = State#state.blocked_tags,
    cleanup_after_worker(Info),
    exit(Pid, shutdown),
    %% Flush messages from this worker.
    receive {worker_reply, Pid, _} -> ok
    after 0 -> ok end,
    State#state{workers = orddict:erase(Pid, Workers),
                blocked_tags = ordsets:del_element(
                                 Info#worker_info.tag,
                                 Blocked)
               }.

kill_all_workers(#state{workers = Workers} = State) ->
    lists:foldl(
      fun({Pid, Info}, S) ->
              kill_worker(Pid, Info, S)
      end,
      State, Workers).

kill_all_workers_with_tag(Tag, #state{workers = Workers} = State) ->
    lists:foldl(
      fun({Pid, Info}, S) ->
              case Tag =:= Info#worker_info.tag of
                  true  -> kill_worker(Pid, Info, S);
                  false -> S
              end
      end, State, Workers).

%%%===================================================================

%%% Worker: Wait for keys to appear

-define(WAIT_FOR_KEYS_RETRIES, 10).

wait_for_keys(State) ->
    Fun = fun wait_for_keys_worker/0,
    dispatch_worker(wait_for_keys, Fun, State).

wait_for_keys_worker() ->
    wait_for_keys_worker(?WAIT_FOR_KEYS_RETRIES).

wait_for_keys_worker(0) ->
    timeout;
wait_for_keys_worker(N) ->
    case aec_keys:pubkey() of
        {ok, _Pubkey} -> keys_ready;
        {error, _} ->
            timer:sleep(500),
            wait_for_keys_worker(N - 1)
    end.

handle_wait_for_keys_reply(keys_ready, State) ->
    start_mining(State#state{keys_ready = true});
handle_wait_for_keys_reply(timeout, State) ->
    %% TODO: We should probably die hard at some point instead of retrying.
    epoch_mining:error("Timed out waiting for keys. Retrying."),
    wait_for_keys(State#state{keys_ready = false}).

%%%===================================================================
%%% Worker: Start mining

start_mining(#state{keys_ready = false} = State) ->
    %% We need to get the keys first
    wait_for_keys(State);
start_mining(#state{mining_state = 'stopped'} = State) ->
    State;
start_mining(#state{key_block_candidate = undefined} = State) ->
    create_key_block_candidate(State);
start_mining(#state{key_block_candidate = #candidate{top_hash = OldHash},
                    top_block_hash = TopHash } = State) when OldHash =/= TopHash ->
    %% Candidate generated with stale top hash.
    %% Regenerate the candidate.
    create_key_block_candidate(State);

start_mining(#state{key_block_candidate = Candidate} = State) ->
    epoch_mining:info("Starting mining"),
    HeaderBin = Candidate#candidate.bin,
    Nonce     = Candidate#candidate.nonce,
    Target    = aec_blocks:target(Candidate#candidate.block),
    Info      = [{top_block_hash, State#state.top_block_hash}],
    aec_events:publish(start_mining, Info),
    Fun = fun() ->
                  {aec_mining:mine(HeaderBin, Target, Nonce)
                  , HeaderBin}
          end,
    dispatch_worker(mining, Fun, State).

handle_mining_reply(_Reply, #state{key_block_candidate = undefined} = State) ->
    %% Something invalidated the block candidate already.
    start_mining(State);
handle_mining_reply({{ok, {Nonce, Evd}}, HeaderBin}, #state{} = State) ->
    Candidate = State#state.key_block_candidate,
    %% Check that the solution is for this block
    case HeaderBin =:= Candidate#candidate.bin of
        true ->
            aec_metrics:try_update([ae,epoch,aecore,mining,blocks_mined], 1),
            State1 = State#state{key_block_candidate = undefined},
            Block = aec_blocks:set_nonce_and_pow(Candidate#candidate.block, Nonce, Evd),
            case handle_mined_block(Block, State1) of
                {ok, State2} ->
                    State2;
                {{error, Reason}, State2} ->
                    epoch_mining:error("Block insertion failed: ~p.", [Reason]),
                    start_mining(State2)
            end;
        _Other ->
            %% This mining effort was for an earlier block candidate.
            epoch_mining:error("Found solution for old block", []),
            start_mining(State)
    end;
handle_mining_reply({{error, no_solution}, _}, State) ->
    Candidate = State#state.key_block_candidate,
    aec_metrics:try_update([ae,epoch,aecore,mining,retries], 1),
    epoch_mining:debug("Failed to mine block, no solution (nonce ~p); "
                       "retrying.", [Candidate#candidate.nonce]),
    retry_mining(State);
handle_mining_reply({{error, {runtime, Reason}}, _}, State) ->
    aec_metrics:try_update([ae,epoch,aecore,mining,retries], 1),
    Candidate = State#state.key_block_candidate,
    epoch_mining:error("Failed to mine block, runtime error; "
                       "retrying with different nonce (was ~p). "
                       "Error: ~p", [Candidate#candidate.nonce, Reason]),
    retry_mining(State).

%%%===================================================================
%%% Retry mining when we failed to find a solution.

retry_mining(S = #state{ key_block_candidate = Candidate }) ->
    start_mining(S#state{ key_block_candidate = bump_nonce(Candidate) }).

bump_nonce(#candidate{ nonce = N, max_nonce = N }) ->
    epoch_mining:info("Failed to mine block, "
    "nonce range exhausted (was ~p)", [N]),
    undefined;
bump_nonce(C = #candidate{ nonce = N }) ->
    C#candidate{ nonce = aec_pow:next_nonce(N) }.

%%%===================================================================
%%% Worker: Start signing microblocks

start_micro_signing(#state{keys_ready = false} = State) ->
    %% We need to get the keys first
    wait_for_keys(State);
start_micro_signing(#state{mining_state = 'stopped'} = State) ->
    State;
start_micro_signing(#state{consensus = #consensus{leader = true}, micro_block_candidate = undefined} = State) ->
    %% We have to wait for a new block candidate first.
    State;
start_micro_signing(#state{consensus = #consensus{leader = true},
                    micro_block_candidate = #candidate{top_hash = MicroBlockHash},
                    top_block_hash = TopHash} = State) when MicroBlockHash =/= TopHash ->
    %% Candidate generated with stale top hash.
    %% Regenerate the candidate.
    State#state{micro_block_candidate = undefined};
start_micro_signing(#state{consensus = #consensus{leader = true},
                           micro_block_candidate = #candidate{block = MicroBlock}} = State) ->
    case is_tag_blocked(micro_sleep, State) of
        true ->
            epoch_mining:debug("Too early to sign micro block, wait a bit longer"),
            State;
        false ->
            epoch_mining:info("Signing microblock"),
            AdjMicroBlock = aec_blocks:set_time_in_msecs(MicroBlock, aeu_time:now_in_msecs()),
            {ok, SignedMicroBlock} = aec_keys:sign_micro_block(AdjMicroBlock),
            State1 = State#state{micro_block_candidate = undefined},
            case handle_signed_block(SignedMicroBlock, State1) of
                {ok, State2} ->
                    State2;
                {{error, Reason}, State2} ->
                    epoch_mining:error("Block insertion failed: ~p.", [Reason]),
                    start_micro_signing(State2)
            end
    end;
start_micro_signing(#state{consensus = Consensus,
                           micro_block_candidate = MicroCandidate,
                           key_block_candidate = KeyBlockCandidate,
                           top_block_hash = SeenHash
                           } = State) ->
    %% Probably no longer the leader
    epoch_mining:debug("Fallback clause, candidate conditions not met. micro: ~p, key: ~p, seen top: ~p, consensus: ~p",
                       [MicroCandidate, KeyBlockCandidate, SeenHash, Consensus]),
    State.

%%%===================================================================
%%% Worker: Timer for sleep between micro blocks

start_micro_sleep(#state{consensus = #consensus{leader = true, micro_block_cycle = Timeout}} = State) ->
    epoch_mining:debug("Starting sleep in between microblocks"),
    Info      = [{start_micro_sleep, State#state.top_block_hash}],
    aec_events:publish(start_micro_sleep, Info),
    Fun = fun() ->
                  timer:sleep(Timeout)
          end,
    dispatch_worker(micro_sleep, Fun, State);
start_micro_sleep(State) ->
    State.

handle_micro_sleep_reply(ok, State) ->
    start_micro_signing(State).

%%%===================================================================
%%% Worker: Generate new block candidates

create_key_block_candidate(#state{keys_ready = false} = State) ->
    %% Keys are needed for creating a candidate
    wait_for_keys(State);
create_key_block_candidate(#state{top_block_hash = TopHash,
                                  beneficiary    = Beneficiary} = State) ->
    epoch_mining:info("Creating key block candidate on the top"),
    Fun = fun() ->
              {aec_block_key_candidate:create(TopHash, Beneficiary), TopHash}
          end,
    dispatch_worker(create_key_block_candidate, Fun, State).

handle_key_block_candidate_reply({{ok, KeyBlockCandidate}, TopHash},
                                 #state{top_block_hash = TopHash} = State) ->
    epoch_mining:info("Created key block candidate "
                      "Its target is ~p (= difficulty ~p).",
                      [aec_blocks:target(KeyBlockCandidate),
                       aec_blocks:difficulty(KeyBlockCandidate)]),
    Candidate = make_key_candidate(KeyBlockCandidate),
    State1 = State#state{key_block_candidate = Candidate},
    start_mining(State1);
handle_key_block_candidate_reply({{ok, _KeyBlockCandidate}, _OldTopHash},
                                 #state{top_block_hash = _TopHash} = State) ->
    epoch_mining:debug("Created key block candidate is already stale, create a new one", []),
    create_key_block_candidate(State);
handle_key_block_candidate_reply({{error, key_not_found}, _}, State) ->
    start_mining(State#state{keys_ready = false});
handle_key_block_candidate_reply({{error, Reason}, _}, State) ->
    epoch_mining:error("Creation of key block candidate failed: ~p", [Reason]),
    create_key_block_candidate(State).

%%%===================================================================
%%% In server context: A block was given to us from the outside world

handle_synced_block(Block, State) ->
    epoch_mining:info("sync_block: ~p", [Block]),
    handle_add_block(Block, State, block_synced).

handle_post_block(Block, State) ->
    case aec_blocks:is_key_block(Block) of
        true ->
            epoch_mining:info("post_block: ~p", [Block]),
            handle_add_block(Block, State, block_received);
        false ->
            epoch_mining:info("post_micro_block: ~p", [Block]),
            handle_add_block(Block, State, micro_block_received)
    end.

handle_mined_block(Block, State) ->
    epoch_mining:info("Block mined: Height = ~p; Hash = ~s",
                      [aec_blocks:height(Block),
                       as_hex(aec_blocks:root_hash(Block))]),
    handle_add_block(Block, State, block_created).

handle_signed_block(Block, State) ->
    epoch_mining:info("Block signed: Height = ~p; Hash = ~s",
        [aec_blocks:height(Block),
            as_hex(aec_blocks:root_hash(Block))]),
    handle_add_block(Block, State, micro_block_created).

as_hex(S) ->
    [io_lib:format("~2.16.0b", [X]) || <<X:8>> <= S].

handle_add_block(#{ key_block := KeyBlock, dir := Dir } = Block, #state{} = State, Origin) ->
    %% Network layer (peer_connection, sync) sanitized KeyBlock to be key block.
    Header = aec_blocks:to_header(KeyBlock),
    %% Always try to insert forward generation - it may contain new unseen information
    CheckFun = case Dir of
                   backward -> fun aec_sync:has_generation/1;
                   forward  -> fun(_) -> false end
               end,
    handle_add_block(Header, CheckFun, Block, State, Origin);
handle_add_block(Block, #state{} = State, Origin) ->
    Header = aec_blocks:to_header(Block),
    handle_add_block(Header, fun aec_chain:has_block/1, Block, State, Origin).

handle_add_block(Header, CheckFun, Block, State, Origin) ->
    {ok, Hash} = aec_headers:hash_header(Header),
    case CheckFun(Hash) of
        true ->
            epoch_mining:debug("Block already in chain", []),
            {ok, State};
        false ->
            case aec_validation:validate_block(Block) of
                ok ->
                    case aec_chain_state:insert_block(Block) of
                        ok ->
                            maybe_publish_block(Origin, Block),
                            case preempt_if_new_top(State, Origin) of
                                no_change ->
                                    {ok, State};
                                {micro_changed, State1 = #state{ consensus = Cons }} ->
                                    {ok, setup_loop(State1, false, Cons#consensus.leader, Origin)};
                                {changed, NewTopBlock, State1} ->
                                    IsLeader = is_leader(NewTopBlock),
                                    %% Don't spend time when we are the leader.
                                    [ aec_tx_pool:garbage_collect() || not IsLeader ],
                                    {ok, setup_loop(State1, true, IsLeader, Origin)}
                            end;
                        {error, Reason} ->
                            lager:error("Couldn't insert block (~p)", [Reason]),
                            {{error, Reason}, State}
                    end;
                {error, {header, Reason}} ->
                    epoch_mining:info("Header failed validation: ~p", [Reason]),
                    {{error, Reason}, State};
                {error, {block, Reason}} ->
                    epoch_mining:info("Block failed validation: ~p", [Reason]),
                    {{error, Reason}, State}
            end
    end.

%% NG-TODO: This is pretty inefficient and can be helped with some info
%%          in the state.
is_leader(NewTopBlock) ->
    LeaderKey =
        case aec_blocks:type(NewTopBlock) of
            key   -> aec_blocks:miner(NewTopBlock);
            micro ->
                {ok, KeyHash} = aec_chain:get_key_hash(aec_blocks:hash_internal_representation(NewTopBlock)),
                {ok, Block} = aec_chain:get_block(KeyHash),
                aec_blocks:miner(Block)
        end,
    case aec_keys:pubkey() of
        {ok, MinerKey} -> LeaderKey =:= MinerKey;
        {error, _}     -> false
    end.

hard_reset_block_generator() ->
    %% Hard reset of aec_block_generator
    exit(whereis(aec_block_generator), kill),
    flush_candidate().

flush_candidate() ->
    receive
        {gproc_ps_event, candidate_block, _} ->
            flush_candidate()
    after 10 ->
        ok
    end.

setup_loop(State = #state{ consensus = Cons }, RestartMining, IsLeader, Origin) ->
    State1 = State#state{ consensus = Cons#consensus{ leader = IsLeader } },
    State2 =
        case Origin of
            block_created when IsLeader ->
                aec_block_generator:start_generation(),
                start_micro_signing(State1);
            block_received when not IsLeader ->
                aec_block_generator:stop_generation(),
                State1;
            micro_block_created when IsLeader ->
                start_micro_sleep(State1);
            Origin when Origin =:= block_created; Origin =:= micro_block_created;
                        Origin =:= block_received; Origin =:= micro_block_received;
                        Origin =:= block_synced ->
                State1
        end,
    case RestartMining of
        true  -> start_mining(State2);
        false -> State2
    end.

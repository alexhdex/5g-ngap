%%% ngap_listen_fsm.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2020 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This {@link //stdlib/gen_statem. gen_statem} behaviour callback
%%% 	module implements a socket handler for incoming SCTP connections in the
%%% 	{@link //ngap. ngap} application.
%%%
-module(ngap_listen_fsm).
-copyright('Copyright (c) 2020 SigScale Global Inc.').

-behaviour(gen_statem).

%% export the ngap_listen_fsm API
-export([]).

%% export the callbacks needed for gen_statem behaviour
-export([init/1, handle_event/4, callback_mode/0,
			terminate/3, code_change/4]).
%% export the callbacks for gen_statem states. 
-export([listening/3]).

-include_lib("kernel/include/inet_sctp.hrl").
-include_lib("kernel/include/logger.hrl").

-type state() :: listening.

-record(statedata,
		{sup :: undefined | pid(),
		assoc_sup :: undefined | pid(),
		socket :: gen_sctp:sctp_socket(),
		options :: [tuple()],
		local_addr :: undefined | inet:ip_address(),
		local_port :: undefined | inet:port_number(),
		fsms = #{} :: #{Assoc :: gen_sctp:assoc_id() => Fsm :: pid()}}).
-type statedata() :: #statedata{}.

%%----------------------------------------------------------------------
%%  The ngap_listen_fsm API
%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%  The ngap_listen_fsm gen_statem callbacks
%%----------------------------------------------------------------------

-spec callback_mode() -> Result
	when
		Result :: gen_statem:callback_mode_result().
%% @doc Set the callback mode of the callback module.
%% @see //stdlib/gen_statem:callback_mode/0
%% @private
%%
callback_mode() ->
	state_functions.

-spec init(Args) -> Result
	when
		Args :: [term()],
		Result :: {ok, State, Data} | {ok, State, Data, Actions}
				| ignore | {stop, Reason},
		State :: state(),
		Data :: statedata(),
		Actions :: Action | [Action],
		Action :: gen_statem:action(),
		Reason :: term().
%% @doc Initialize the {@module} finite state machine.
%% @see //stdlib/gen_statem:init/1
%% @private
%%
init([Sup, Opts] = _Args) ->
	Options = [{active, once}, {reuseaddr, true},
			{sctp_events, #sctp_event_subscribe{adaptation_layer_event = true}},
			{sctp_default_send_param, #sctp_sndrcvinfo{ppid = 60}},
			{sctp_adaptation_layer, #sctp_setadaptation{adaptation_ind = 60}}
			| Opts],
	try
		case gen_sctp:open(Options) of
			{ok, Socket} ->
				case gen_sctp:listen(Socket, true) of
					ok ->
						case inet:sockname(Socket) of
							{ok, {LocalAddr, LocalPort}} ->
								process_flag(trap_exit, true),
								StateData = #statedata{sup = Sup,
										options = Options,
										socket = Socket,
										local_addr = LocalAddr,
										local_port = LocalPort},
								{ok, listening, StateData, 0};
							{error, Reason} ->
								gen_sctp:close(Socket),
								throw(Reason)
						end;
					{error, Reason} ->
						gen_sctp:close(Socket),
						throw(Reason)
				end;
			{error, Reason} ->
				throw(Reason)
		end
	catch
		Reason1 ->
			?LOG_ERROR("Failed to open socket~n"
					"error: ~w~noptions: ~w~n", [Reason1, Options]),
			{stop, Reason1}
	end.

-spec listening(EventType, EventContent, Data) -> Result
	when
		EventType :: gen_statem:event_type(),
		EventContent :: term(),
		Data :: statedata(),
		Result :: gen_statem:event_handler_result(state()).
%% @doc Handles events received in the <em>listening</em> state.
%% @private
%%
listening(timeout = _EventType, _EventContent,
		#statedata{assoc_sup = undefined} = Data) ->
   {next_state, listening, get_assoc_sup(Data)};
listening(EventType, EventContent,
		#statedata{assoc_sup = undefined} = Data) ->
	listening(EventType, EventContent, get_assoc_sup(Data));
listening(info, {sctp, Socket, FromAddr, FromPort,
		{_AncData, #sctp_assoc_change{state = comm_up,
		assoc_id = Assoc, outbound_streams = OutStreams,
		inbound_streams = InStreams} = AssocChange}}, Data) ->
	?LOG_INFO("SCTP peer association change~n"
			"address: ~w~nstreams: ~w~nassociation: ~w~nstate: ~w~n",
			[{FromAddr, FromPort}, {OutStreams, InStreams}, Assoc, comm_up]),
	accept(Socket, FromAddr, FromPort, AssocChange, listening, Data);
listening(info, {sctp, Socket, FromAddr, FromPort,
		{_AncData, #sctp_assoc_change{state = AssocState,
		assoc_id = Assoc, outbound_streams = OutStreams,
		inbound_streams = InStreams}}}, Data) ->
	?LOG_WARNING("SCTP peer association change~n"
			"address: ~w~nstreams: ~w~nassociation: ~w~nstrate: ~w~n",
			[{FromAddr, FromPort}, {OutStreams, InStreams}, Assoc, AssocState]),
	ok = inet:setopts(Socket, [{active, once}]),
	{next_state, listening, Data};
listening(info, {sctp, Socket, _FromAddr, _FromPort,
		{_AncData, #sctp_paddr_change{state = AddressState,
		addr = {PeerAddr, PeerPort}, assoc_id = Assoc}}}, Data) ->
	?LOG_WARNING("SCTP peer address state change~n"
			"address: ~w~nassociation: ~w~nstate: ~w~n",
			[{PeerAddr, PeerPort}, Assoc, AddressState]),
	ok = inet:setopts(Socket, [{active, once}]),
	{next_state, listening, Data};
listening(cast, {'M-SCTP_RELEASE', request, Ref, From},
		#statedata{socket = Socket} = Data) ->
	gen_server:cast(From,
			{'M-SCTP_RELEASE', confirm, Ref, gen_sctp:close(Socket)}),
	{stop, {shutdown, {self(), release}}, Data};
listening(info, {'EXIT', _Pid, {shutdown, {{_EP, Assoc}, _Reason}}},
		#statedata{fsms = Fsms} = Data) ->
	NewFsms = maps:remove(Assoc, Fsms),
	NewData = Data#statedata{fsms = NewFsms},
	{next_state, listening, NewData};
listening(info, {'EXIT', Pid, shutdown},
		#statedata{fsms = Fsms} = Data) ->
	Fdel = fun Fdel({Assoc, P, _Iter}) when P ==  Pid ->
		       Assoc;
		   Fdel({_Key, _Val, Iter}) ->
		       Fdel(maps:next(Iter));
		   Fdel(none) ->
		       none
	end,
	Iter = maps:iterator(Fsms),
	Key = Fdel(maps:next(Iter)),
	NewFsms = maps:remove(Key, Fsms),
	NewData = Data#statedata{fsms = NewFsms},
	{next_state, listening, NewData}.

-spec handle_event(EventType, EventContent, State, Data) -> Result
	when
		EventType :: gen_statem:event_type(),
		EventContent :: term(),
		State :: state(),
		Data :: statedata(),
		Result :: gen_statem:event_handler_result(State).
%% @doc Handles events received in the any state.
%% @private
%%
handle_event(_EventType, _EventContent, State, Data) ->
	{next_state, State, Data}.

-spec terminate(Reason, State, Data) -> any()
	when
		Reason :: normal | shutdown | {shutdown, term()} | term(),
      State :: state(),
		Data ::  statedata().
%% @doc Cleanup and exit.
%% @see //stdlib/gen_statem:terminate/3
%% @private
%%
terminate(_Reason, _State, #statedata{socket = Socket} = Data) ->
	case gen_sctp:close(Socket) of
		ok ->
			ok;
		{error, Reason1} ->
			?LOG_ERROR("Failed to close socket~n"
					"socket: ~w~nerror: ~w~nstatedata: ~p~n",
					[Socket, Reason1, Data])
	end.

-spec code_change(OldVsn, OldState, OldData, Extra) -> Result
	when
		OldVsn :: Version | {down, Version},
		Version ::  term(),
		OldState :: state(),
		OldData :: statedata(),
		Extra :: term(),
		Result :: {ok, NewState, NewData} |  Reason,
		NewState :: state(),
		NewData :: statedata(),
		Reason :: term().
%% @doc Update internal state data during a release upgrade&#047;downgrade.
%% @see //stdlib/gen_statem:code_change/3
%% @private
%%
code_change(_OldVsn, OldState, OldData, _Extra) ->
	{ok, OldState, OldData}.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------

%% @hidden
get_assoc_sup(#statedata{sup = Sup} = Data) ->
	Children = supervisor:which_children(Sup),
	{_, AssocSup, _, _} = lists:keyfind(ngap_association_sup, 1, Children),
	Data#statedata{assoc_sup = AssocSup}.

%% @hidden
accept(Socket, Address, Port,
		#sctp_assoc_change{assoc_id = Assoc} = AssocChange,
		State, #statedata{sup = EpSup, assoc_sup = AssocSup,
		fsms = Fsms} = Data) ->
	case gen_sctp:peeloff(Socket, Assoc) of
		{ok, NewSocket} ->
			case supervisor:start_child(AssocSup,
					[[EpSup, NewSocket, Address, Port,
					AssocChange, self()], []]) of
				{ok, Fsm} ->
					case gen_sctp:controlling_process(NewSocket, Fsm) of
						ok ->
							ok = inet:setopts(Socket, [{active, once}]),
							NewFsms = Fsms#{Assoc => Fsm},
							link(Fsm),
							NewData = Data#statedata{fsms = NewFsms},
							{next_state, State, NewData};
						{error, Reason} ->
							{stop, Reason, Data}
					end;
				{error, Reason} ->
					{stop, Reason, Data}
			end;
		{error, Reason} ->
			{stop, Reason, Data}
	end.


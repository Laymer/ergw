%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf).

%%-behaviour(gtp_api).
-behaviour(gen_server).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([start/4, validate_options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

validate_options(Options) ->
    lager:debug("TDF Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, [], map).

validate_option(protocol, ip) ->
    ip;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_option(nodes, [S|_] = Value)
  when is_list(S) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

start(Socket, Name, Protocol, Opts) ->
    gen_server:start(?MODULE, [Socket, Name, Protocol, Opts], []),
    ok.

%%====================================================================
%% gen_server API
%%====================================================================

init([Socket, Name, Protocol, #{apn := APN, node_selection := NodeSelect} = Opts]) ->
    process_flag(trap_exit, true),
    lager:debug("APN: ~p", [APN]),

    {ok, {VRF, VRFOpts}} = ergw:vrf_lookup(APN),
    lager:debug("VRF: ~p, Opts: ~p", [VRF, VRFOpts]),

    Services = [{"x-3gpp-upf", "x-sxc"}],
    {ok, SxPid} = ergw_sx_node:select_sx_node(APN, Services, NodeSelect),
    lager:debug("SxPid: ~p", [SxPid]),

    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

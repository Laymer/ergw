-module(ergw_test_sx_up).

-behaviour(gen_server).

%% API
-export([start/2, stop/1, send/2, reset/1, history/1, accounting/2,
	enable/1, disable/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").

-define(SERVER, ?MODULE).

-record(state, {sx, gtp, accounting, enabled, cp_ip, cp_seid,
		up_ip, up_seid, recovery_ts, seq_no, history}).

%%%===================================================================
%%% API
%%%===================================================================

start(Role, IP) ->
    gen_server:start({local, server_name(Role)}, ?MODULE, [IP], []).

stop(Role) ->
    gen_server:call(server_name(Role), stop).

send(Role, Msg) ->
    gen_server:call(server_name(Role), {send, Msg}).

reset(Role) ->
    gen_server:call(server_name(Role), reset).

history(Role) ->
    gen_server:call(server_name(Role), history).

accounting(Role, Acct) ->
    gen_server:call(server_name(Role), {accounting, Acct}).

enable(Role) ->
    gen_server:call(server_name(Role), {enabled, true}).

disable(Role) ->
    gen_server:call(server_name(Role), {enabled, false}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([IP]) ->
    process_flag(trap_exit, true),

    SockOpts = [binary, {ip, IP}, {active, true}, {reuseaddr, true}],
    {ok, GtpSocket} = gen_udp:open(?GTP1u_PORT, SockOpts),
    {ok, SxSocket} = gen_udp:open(8805, SockOpts),
    State = #state{
	       sx = SxSocket,
	       gtp = GtpSocket,
	       accounting = on,
	       enabled = true,
	       cp_seid = 0,
	       up_ip = ergw_inet:ip2bin(IP),
	       up_seid = ergw_sx_socket:seid(),
	       recovery_ts = erlang:system_time(seconds),
	       seq_no = erlang:unique_integer([positive]) rem 16#ffffff,
	       history = []
	      },
    {ok, State}.

handle_call(reset, _From, State0) ->
    State = State0#state{
	      accounting = on,
	       enabled = true,
	      cp_ip = undefined,
	      cp_seid = 0,
	      up_seid = ergw_sx_socket:seid(),
	      history = []
	     },
    {reply, ok, State};

handle_call({enabled, Bool}, _From, State) ->
    {reply, ok, State#state{enabled = Bool}};

handle_call(history, _From, #state{history = Hist} = State) ->
    {reply, lists:reverse(Hist), State};

handle_call({accounting, Acct}, _From, State) ->
    {reply, ok, State#state{accounting = Acct}};

handle_call({send, #pfcp{} = Msg}, _From,
	    #state{sx = SxSocket, cp_ip = IP, cp_seid = SEID, seq_no = SeqNo} = State) ->
    BinMsg = pfcp_packet:encode(Msg#pfcp{seid = SEID, seq_no = SeqNo}),
    ok = gen_udp:send(SxSocket, IP, 8805, BinMsg),
    {reply, ok, State#state{seq_no = (SeqNo + 1) rem 16#ffffff}};

handle_call({send, Msg}, _From,
	    #state{gtp = GtpSocket, cp_ip = IP} = State)
  when is_binary(Msg) ->
    [[SxTEI, _SxPid]] = ets:match(gtp_context_reg, {{'cp-socket',{teid,'gtp-u','$1'}},'$2'}),
    BinMsg = gtp_packet:encode(#gtp{version = v1, type = g_pdu, tei = SxTEI, ie = Msg}),
    ok = gen_udp:send(GtpSocket, IP, ?GTP1u_PORT, BinMsg),
    {reply, ok, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, _, _, _, _}, #state{enabled = false} = State) ->
    {noreply, State};

handle_info({udp, SxSocket, IP, InPortNo, Packet},
	    #state{sx = SxSocket, history = Hist} = State0) ->
    try
	Msg = pfcp_packet:decode(Packet),
	{Reply, State} = handle_message(Msg, State0#state{history = [Msg|Hist]}),
	case Reply of
	    #pfcp{} ->
		BinReply = pfcp_packet:encode(Reply#pfcp{seq_no = Msg#pfcp.seq_no}),
		ok = gen_udp:send(SxSocket, IP, InPortNo, BinReply);
	    _ ->
		ok
	end,
	{noreply, State}
    catch
	Class:Error ->
	    ct:fail("Sx Socket Error: ~p:~p~n~p", [Class, Error, erlang:get_stacktrace()]),
	    {stop, error, State0}
    end.

terminate(_Reason, #state{sx = SxSocket}) ->
    catch gen_udp:close(SxSocket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

server_name(Role) ->
    binary_to_atom(
      << (atom_to_binary(?SERVER, latin1))/binary, $_, (atom_to_binary(Role, latin1))/binary>>,
      latin1).

make_sx_response(heartbeat_request)             -> heartbeat_response;
make_sx_response(pfd_management_request)        -> pfd_management_response;
make_sx_response(association_setup_request)     -> association_setup_response;
make_sx_response(association_update_request)    -> association_update_response;
make_sx_response(association_release_request)   -> association_release_response;
make_sx_response(node_report_request)           -> node_report_response;
make_sx_response(session_set_deletion_request)  -> session_set_deletion_response;
make_sx_response(session_establishment_request) -> session_establishment_response;
make_sx_response(session_modification_request)  -> session_modification_response;
make_sx_response(session_deletion_request)      -> session_deletion_response;
make_sx_response(session_report_request)        -> session_report_response.

f_seid(SEID, IP) when size(IP) == 4 ->
    #f_seid{seid = SEID, ipv4 = IP};
f_seid(SEID, IP) when size(IP) == 16 ->
    #f_seid{seid = SEID, ipv6 = IP}.

choose_control_ip(IP4, _IP6, #state{up_ip = IP})
  when size(IP) == 4, is_binary(IP4) ->
    IP4;
choose_control_ip(_IP4, IP6, #state{up_ip = IP})
  when size(IP) == 16, is_binary(IP6) ->
    IP6.

user_plane_ip_resource_information(VRF, #state{up_ip = IP})
  when size(IP) == 4 ->
    #user_plane_ip_resource_information{
       network_instance = vrf:normalize_name(VRF),
       ipv4 = ergw_inet:ip2bin(?LOCALHOST_IPv4)
      };
user_plane_ip_resource_information(VRF, #state{up_ip = IP})
  when size(IP) == 16 ->
    #user_plane_ip_resource_information{
       network_instance = vrf:normalize_name(VRF),
       ipv6 = ergw_inet:ip2bin(?LOCALHOST_IPv6)
      }.

sx_reply(Type, State) ->
    sx_reply(Type, undefined, [], State).
sx_reply(Type, IEs, State) ->
    sx_reply(Type, undefined, IEs, State).
sx_reply(Type, SEID, IEs, State) ->
    {#pfcp{version = v1, type = Type, seid = SEID, ie = IEs}, State}.

handle_message(#pfcp{type = heartbeat_request}, #state{recovery_ts = RecoveryTS} = State) ->
    IEs = [#recovery_time_stamp{
	      time = ergw_sx_node:seconds_to_sntp_time(RecoveryTS)}],
    sx_reply(heartbeat_response, undefined, IEs, State);

handle_message(#pfcp{type = association_setup_request},
	       #state{recovery_ts = RecoveryTS} = State) ->
    RespIEs =
	[#node_id{id = [<<"test">>, <<"server">>]},
	 #pfcp_cause{cause = 'Request accepted'},
	 #recovery_time_stamp{
	    time = ergw_sx_node:seconds_to_sntp_time(RecoveryTS)},
	 user_plane_ip_resource_information([<<"cp">>], State),
	 user_plane_ip_resource_information([<<"irx">>], State),
	 user_plane_ip_resource_information([<<"proxy-irx">>], State),
	 user_plane_ip_resource_information([<<"remote-irx">>], State)
	],
    sx_reply(association_setup_response, RespIEs, State);

handle_message(#pfcp{type = session_establishment_request, seid = 0,
		     ie = #{f_seid := #f_seid{seid = ControlPlaneSEID,
					      ipv4 = ControlPlaneIP4,
					      ipv6 = ControlPlaneIP6}}},
	       #state{up_ip = IP, up_seid = UserPlaneSEID} = State0) ->
    ControlPlaneIP = choose_control_ip(ControlPlaneIP4, ControlPlaneIP6, State0),
    RespIEs =
	[#pfcp_cause{cause = 'Request accepted'},
	 f_seid(UserPlaneSEID, IP)],
    State = State0#state{cp_ip = ergw_inet:bin2ip(ControlPlaneIP),
			 cp_seid = ControlPlaneSEID},
    sx_reply(session_establishment_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_modification_request, seid = UserPlaneSEID, ie = ReqIEs},
	      #state{accounting = Acct,
		     cp_seid = ControlPlaneSEID,
		     up_seid = UserPlaneSEID} = State) ->
    RespIEs =
	case {Acct, maps:is_key(query_urr, ReqIEs)} of
	    {on, true} ->
		[#pfcp_cause{cause = 'Request accepted'},
		 #usage_report_smr{
		    group =
			[#urr_id{id = 1},
			 #usage_report_trigger{immer = 1},
			 #volume_measurement{
			    total = 6,
			    uplink = 4,
			    downlink = 2
			   },
			 #tp_packet_measurement{
			    total = 4,
			    uplink = 3,
			    downlink = 1
			   }
			]
		   }
		];
	    _ ->
		[#pfcp_cause{cause = 'Request accepted'}]
	end,
    sx_reply(session_modification_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_deletion_request, seid = UserPlaneSEID},
	       #state{cp_seid = ControlPlaneSEID,
		      up_seid = UserPlaneSEID} = State) ->
    RespIEs = [#pfcp_cause{cause = 'Request accepted'}],
    sx_reply(session_deletion_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = ReqType, seid = SendingUserPlaneSEID},
	      #state{cp_seid = ControlPlaneSEID,
		     up_seid = OurUserPlaneSEID} = State)
  when
      ReqType == session_set_deletion_request orelse
      ReqType == session_establishment_request orelse
      ReqType == session_modification_request orelse
      ReqType == session_deletion_request ->
    {SEID, RespIEs} =
	if SendingUserPlaneSEID /= OurUserPlaneSEID ->
		{0, [#pfcp_cause{cause = 'Session context not found'}]};
	   true ->
		{ControlPlaneSEID, [#pfcp_cause{cause = 'System failure'}]}
	end,
    sx_reply(make_sx_response(ReqType), SEID, RespIEs, State);

handle_message(#pfcp{type = ReqType}, State)
  when
      ReqType == heartbeat_response orelse
      ReqType == pfd_management_response orelse
      ReqType == association_setup_response orelse
      ReqType == association_update_response orelse
      ReqType == association_release_response orelse
      ReqType == version_not_supported_response orelse
      ReqType == node_report_response orelse
      ReqType == session_set_deletion_response orelse
      ReqType == session_establishment_response orelse
      ReqType == session_modification_response orelse
      ReqType == session_deletion_response orelse
      ReqType == session_report_response ->
    {noreply, State}.

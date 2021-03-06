-module(dht_routing_table_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-record(state,
	{ self,
	  nodes = [],
	  deleted = []
    }).

%% Generators
%% ----------

bucket() ->
    MaxID = 1 bsl 160,
    bucket(0, MaxID).
    
bucket(Low, High) when High - Low < 8 -> return({Low, High});
bucket(Low, High) ->
  Diff = High - Low,
  Half = High - (Diff div 2),

  frequency([
    {1, return({Low, High})},
    {8, ?SHRINK(
            oneof([?LAZY(bucket(Half, High)),
                   ?LAZY(bucket(Low, Half))]),
            [return({Low, High})])}
  ]).

%% Insertion of new entries into the routing table
%% -----------------------------------------------
insert({ID, IP, Port}) ->
	routing_table:insert({ID, IP, Port}).
	
insert_args(#state {}) ->
	?LET({ID, IP, Port}, {dht_eqc:id(), dht_eqc:ip(), dht_eqc:port()},
	  [{ID, IP, Port}]).
	  
insert_next(#state { nodes = Nodes } = State, _V, [Node]) ->
	State#state { nodes = Nodes ++ [Node] }.

%% Ask the system for the current state table ranges
%% -------------------------------------------------
ranges() ->
	routing_table:ranges().
	
ranges_args(_S) ->
	[].

%% Range validation is simple. The set of all ranges should form a contiguous
%% space of split ranges. If it doesn't something is wrong.
ranges_post(#state {}, [], Ranges) ->
	contiguous(Ranges).

%% Ask in what range a random ID falls in
%% --------------------------------------
range(ID) ->
	routing_table:range(ID).
	
range_args(_S) ->
	[dht_eqc:id()].
	
%% Delete a node from the routing table
%% In this case, the node does not exist
%% ------------------------------------
delete_not_existing(Node) ->
	routing_table:delete(Node).
	
delete_not_existing_args(#state {}) ->
	?LET({ID, IP, Port}, {dht_eqc:id(), dht_eqc:ip(), dht_eqc:port()},
	  [{ID, IP, Port}]).
	  
delete_not_existing_pre(#state { nodes = Ns }, [N]) ->
    not lists:member(N, Ns).

%% Delete a node from the routing table
%% In this case, the node does exist in the table
%% ------------------------------------
delete(Node) ->
	routing_table:delete(Node).
	
delete_pre(S) ->
	has_nodes(S).

delete_args(#state { nodes = Ns}) ->
	[elements(Ns)].
	
delete_next(#state { nodes = Ns, deleted = Ds } = State, _, [Node]) ->
	State#state {
		nodes = lists:delete(Node, Ns),
		deleted = Ds ++ [Node]
	}.

%% Ask for members of a given ID
%% Currently, we only ask for existing members, but this could also fault-inject
%% -----------------------------
members(ID) ->
	routing_table:members(ID).

members_pre(S) ->
    has_nodes(S).

members_args(#state { nodes = Ns }) ->
	[elements(ids(Ns))].

members_post(#state{}, [_ID], Res) -> length(Res) =< 8.

%% Ask for membership of the Routing Table
%% ---------------------------------------
is_member(Node) ->
    routing_table:is_member(Node).

is_member_pre(S) ->
	has_nodes(S) orelse has_deleted_nodes(S).

is_member_args(#state { nodes = Ns, deleted = DNs }) ->
	[elements(Ns ++ DNs)].

is_member_post(#state { deleted = DNs }, [N], Res) ->
    case lists:member(N, DNs) of
      true ->
        %% Among the deleted nodes, must never be in the routing table
        Res == false;
      false ->
        %% Not among the deleted nodes, can be a subset so this is always ok
        true
    end.

%% Ask for the node list
%% -----------------------
node_list() ->
    routing_table:node_list().
    
node_list_args(_S) ->
	[].
	
node_list_post(#state { nodes = Ns }, _Args, RNs) ->
	is_subset(RNs, Ns).

%% Ask if the routing table has a bucket
%% -------------------------------------
has_bucket(B) ->
	routing_table:has_bucket(B).
	
has_bucket_args(_S) ->
	[bucket()].

%% Ask who is closest to a given ID
%% --------------------------------
closest_to(ID, Num) ->
	routing_table:closest_to(ID, fun(_X) -> true end, Num).
	
closest_to_args(#state { }) ->
	[dht_eqc:id(), nat()].

%% Currently skipped commands
%% closest_to(ID, Self, Buckets, Filter, Num)/5

%% Invariant
%% ---------
%%
%% · No bucket has more than 8 members
%% · Buckets can't overlap
%% · Members of a bucket share a property: a common prefix
%% · The common prefix is given by the depth/width of the bucket
invariant(_S) ->
	routing_table:invariant().


%% Weights
%% -------
%%
%% It is more interesting to manipulate the structure than it is to query it:
weight(_S, insert) -> 3;
weight(_S, delete) -> 3;
weight(_S, _Cmd) -> 1.

%% Properties
%% ----------

prop_seq() ->
    ?SETUP(fun() ->
        ok,
        fun() -> ok end
      end,
    ?FORALL(Self, dht_eqc:id(),
    ?FORALL(Cmds, commands(?MODULE, #state { self = Self}),
      begin
        ok = routing_table:reset(Self),
        {H, S, R} = run_commands(?MODULE, Cmds),
        aggregate(command_names(Cmds),
          pretty_commands(?MODULE, Cmds, {H, S, R}, R == ok))
      end))).

%% Internal functions
%% ------------------

contiguous([]) -> true;
contiguous([{_Min, _Max}]) -> true;
contiguous([{_Low, M1}, {M2, High} | T]) when M1 == M2 ->
  contiguous([{M2, High} | T]);
contiguous([X, Y | _T]) ->
  {error, X, Y}.

has_nodes(#state { nodes = [] }) -> false;
has_nodes(#state { nodes = [_|_] }) -> true.

has_deleted_nodes(#state { deleted = [] }) -> false;
has_deleted_nodes(#state { deleted = [_|_] }) -> true.

ids(Nodes) ->
  [ID || {ID, _, _} <- Nodes].

is_subset([X | Xs], Set) ->
    lists:member(X, Set) andalso is_subset(Xs, Set);
is_subset([], _Set) -> true.

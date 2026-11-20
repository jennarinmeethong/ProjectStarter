---------------------------- MODULE ExportWorkers ----------------------------
(* Workers claim queued export jobs under a lease. A lease can expire, which puts the job back on the queue while
   the old worker may still be running it. Completion is therefore fenced: a worker may commit a result only while
   it is the job's current owner. TLC checks the invariants below over every interleaving of the finite model in
   ExportWorkers.cfg (bash ci/model-check.sh). The bounds are part of the result: two workers and two jobs. *)
CONSTANTS Workers, Jobs, None

VARIABLES state, owner, holding, writer
vars == <<state, owner, holding, writer>>

TypeOK ==
  /\ state \in [Jobs -> {"queued", "running", "ready", "failed"}]
  /\ owner \in [Jobs -> Workers \cup {None}]
  /\ holding \in [Workers -> SUBSET Jobs]
  /\ writer \in [Jobs -> Workers \cup {None}]

Init ==
  /\ state = [j \in Jobs |-> "queued"]
  /\ owner = [j \in Jobs |-> None]
  /\ holding = [w \in Workers |-> {}]
  /\ writer = [j \in Jobs |-> None]

\* Atomic claim (compare-and-set on the queued state).
Claim(w, j) ==
  /\ state[j] = "queued"
  /\ state' = [state EXCEPT ![j] = "running"]
  /\ owner' = [owner EXCEPT ![j] = w]
  /\ holding' = [holding EXCEPT ![w] = @ \cup {j}]
  /\ UNCHANGED writer

\* The lease expires: the job is queued again, but its worker does not know yet and keeps holding it.
Expire(j) ==
  /\ state[j] = "running"
  /\ state' = [state EXCEPT ![j] = "queued"]
  /\ owner' = [owner EXCEPT ![j] = None]
  /\ UNCHANGED <<holding, writer>>

\* The fence checked when a worker commits.
CanCommit(w, j) == state[j] = "running" /\ owner[j] = w

Complete(w, j) ==
  /\ j \in holding[w]
  /\ CanCommit(w, j)
  /\ state' = [state EXCEPT ![j] = "ready"]
  /\ writer' = [writer EXCEPT ![j] = w]
  /\ holding' = [holding EXCEPT ![w] = @ \ {j}]
  /\ UNCHANGED owner

Fail(w, j) ==
  /\ j \in holding[w]
  /\ CanCommit(w, j)
  /\ state' = [state EXCEPT ![j] = "failed"]
  /\ holding' = [holding EXCEPT ![w] = @ \ {j}]
  /\ UNCHANGED <<owner, writer>>

\* A worker whose commit is rejected drops the job.
Abandon(w, j) ==
  /\ j \in holding[w]
  /\ ~CanCommit(w, j)
  /\ holding' = [holding EXCEPT ![w] = @ \ {j}]
  /\ UNCHANGED <<state, owner, writer>>

Next ==
  \/ \E w \in Workers, j \in Jobs : Claim(w, j) \/ Complete(w, j) \/ Fail(w, j) \/ Abandon(w, j)
  \/ \E j \in Jobs : Expire(j)

Spec == Init /\ [][Next]_vars

\* `ready` always has an artifact, as in the domain type.
ReadyHasWriter == \A j \in Jobs : state[j] = "ready" => writer[j] /= None

\* A ready export was written by the job's owner, never by a worker whose lease had expired.
ReadyWrittenByOwner == \A j \in Jobs : state[j] = "ready" => writer[j] = owner[j]
=============================================================================

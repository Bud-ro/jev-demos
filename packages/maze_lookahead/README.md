# maze_lookahead

Checking spatial reasoning and its ability to think ahead.

For 10 trials, give Jev state showing an ASCII maze. We trial this on mazes of
size 5, 10, 20, 50, 100, 200, 500, 1000 (we start hitting token limits kind of
quick here). Then multiply that by the number of choices we give the model to
work with: choices of the form "What should be the Nth move from this position"
with UP/LEFT/RIGHT/DOWN/NONE. Supposedly it doesn't even matter if we ask these
questions all at once, it won't affect the other answers, so we ask as _many_ as
we can (probably can push over 100). That lets us build out data such as:

- The max number of moves it can make without error (backtracking, bumping into
  a wall, or moving off the goal after already stepping on it, ignoring predicted
  steps after the first NONE step) for any given puzzle size of NxN.
- Average number of iterations to get to the end.

Minimally: "only follow step N=1 in a loop" plus "follow ALL steps N=1, N=2, etc.
that the AI gave (even invalid ones)". Hard cap on move count: 5*minimum_number_of_moves.

Runs "single threaded" (never querying Jev in parallel to be respectful). Quick
preset is ~10 minutes, full is under 1hr. Data is recorded so we can generate
visuals (particularly GIFs) later.

    dart run maze_lookahead plan                       # napkin math
    dart run maze_lookahead --preset smoke --mock all  # [TODO]
    dart run maze_lookahead --preset quick all

Later: does adding "history" to state allow it to solve mazes more reliably in
the cases where it gets lost? Save that for after our first initial experiment.

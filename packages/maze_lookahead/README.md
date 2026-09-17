# maze_lookahead

Puts Jev's maze solving skills to the test. This demo tests the model's ability to use spatial reasoning, and in particular apply that spatial reasoning to future steps. The most interesting application here is _simultaneous move making_. Instead of just asking for the next move, we ask for the next N moves with N different questions. Any invalid move (backtracking, bumping into a wall, or moving off the goal after stepping on it) is a failure for our purposes.

Even though we ask N questions, we test the model's ability when only following the first M decisions, across different NxN mazes of different sizes.

```bash
dart run maze_lookahead plan                       # napkin math
dart run maze_lookahead --preset smoke --mock all  # Use BFS and deterministically solve puzzles
dart run maze_lookahead --preset quick all         # Real run
```

## Other Experimental Settings

Below are a handful of things you might try to see the results:
- Does adding move history to `state` allow Jev to solve mazes more reliably? Or does it help in cases where it gets lost? 
- Does adding a "recommended" step size, "difficulty" of maze, etc. change results?

# maze_lookahead

Puts Jev's maze solving skills to the test. This demo tests the model's ability to use spatial reasoning, and in particular apply that spatial reasoning to future steps. The most interesting application here is _simultaneous move making_. Instead of just asking for the next move, we ask for the next N moves with N different questions. Any invalid move (backtracking, bumping into a wall, or moving off the goal after stepping on it) is a failure for our purposes.

Even though we ask N questions, we test the model's ability when only following the first M decisions, across different NxN mazes of different sizes.

```bash
dart run maze_lookahead plan                       # napkin math
dart run maze_lookahead --preset smoke --mock all  # Use BFS and deterministically solve puzzles
dart run maze_lookahead --preset quick all         # Real run
dart run maze_lookahead --recipes pr_like_nc --trials 10 --iter-cap 40 ablate   # best recipe
```

## Results

Jev is bad at this. On the quick preset (ten 5x5 mazes down to two 100x100, 100 step questions per request) it solved zero mazes with `#` walls and zero with `█` walls; the block character only cost about 50% more tokens. Its plan is a beeline toward G (right, then down, then NONE) with 35 to 46% accuracy on the very next move, and it never answers UP. Telling it what sits on the four adjacent tiles removes wall bumps entirely, and with that hint plus a single next-move question it solves 6/10 5x5 mazes, 4 of them on the optimal path; every failure is a wrong turn at a fork followed by oscillating in the dead end. Identical requests do not always get identical answers. Meanwhile the "Jev at home" DiffusionGemma structured-read demo in [vllm-project/vllm#57250](https://github.com/vllm-project/vllm/pull/57250) walks the same style of 5x5 maze (one maze shown) to G in 20 optimal moves with no adjacency hints, one read per move. Raw data for every run is under `results/`.

## Other Experimental Settings

Below are a handful of things you might try to see the results:
- Does adding move history to `state` allow Jev to solve mazes more reliably? Or does it help in cases where it gets lost? 
- Does adding a "recommended" step size, "difficulty" of maze, etc. change results?

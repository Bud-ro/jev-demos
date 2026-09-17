# maze_graph

Port of [pahndev/Type-Safe-Maze-Demo-](https://github.com/pahndev/Type-Safe-Maze-Demo-) into this harness, then scaled: bigger mazes, N-step questions, a full-observation mode, and code baselines under the same move cap.

What that demo does that `maze_lookahead` did not: the state is a graph (cell ids, row/column, exits of visited cells, full history, visit counts), not an ASCII picture; the Choice lists only the legal exits of the current cell, so walking into a wall is impossible; backtracking is allowed; one question per move; mazes have extra passages (cycles). It is an exploration task, not "read the map and plan".

```bash
dart run maze_graph --preset theirs plan             # napkin math
dart run maze_graph --preset theirs                  # exact original: 5x5, k=1, cap 80
dart run maze_graph --preset quick                   # 5..50, k=10 lookahead, partial observation
dart run maze_graph --preset quick --observation full --sizes 5,10,20
dart run maze_graph --preset theirs --sizes 5,10 --extra 0   # perfect mazes
```

## Results

Their 5x5 setup reproduces: 10/10 solved at 1.10x optimal, 97% of moves reduce the distance to G. It does not scale: 10x10 4/5 at 1.38x, 20x20 0/3, 50x50 0/2, with revisits climbing from 3% to 55% of moves. At every real fork Jev picks the exit nearest the goal by row+column (100%, 93%, 72% of forks at 5, 10, 20), and a three-line code policy doing exactly that solves 100%, 95%, 40% under the same cap, so on this task Jev is a noisy greedy walker rather than a planner. Extra questions for moves 2..k score at chance (~25%), and a k=1 control reproduced the k=10 run move for move, so batching is free and useless here. Listing every cell's exits (full observation) made 5x5 and 10x10 slightly worse at 3.5x the tokens. Perfect mazes (no cycles) are easier for it: 13/13 solved at 1.00 to 1.06x, because visit counts force it back out of dead ends. Raw data for every run is under `results/`; total spend for this package was about $0.80.

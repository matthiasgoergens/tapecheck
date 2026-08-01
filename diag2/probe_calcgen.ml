(* Generation alone, no engine: how big does the recursive expression
   generator get at each size? Suspicion is that recursive_union with
   two recursive branches out of three explodes, since size decrements
   per level but branching is 2. *)
open Base
module G = Base_quickcheck.Generator

type expr = Lit of int | Add of expr * expr | Div of expr * expr

let rec nodes = function
  | Lit _ -> 1
  | Add (a, b) | Div (a, b) -> 1 + nodes a + nodes b

let gen =
  G.recursive_union
    [ G.map G.int ~f:(fun n -> Lit n) ]
    ~f:(fun self ->
      [ G.map (G.both self self) ~f:(fun (a, b) -> Add (a, b))
      ; G.map (G.both self self) ~f:(fun (a, b) -> Div (a, b))
      ])

let () =
  List.iter [ 2; 4; 6; 8; 10; 15; 20 ] ~f:(fun size ->
    let t0 = Unix.gettimeofday () in
    let total = ref 0 and worst = ref 0 in
    let random = Splittable_random.of_int 42 in
    let n = 200 in
    for _ = 1 to n do
      let e = Base_quickcheck.Generator.generate gen ~size ~random in
      let k = nodes e in
      total := !total + k;
      worst := Int.max !worst k
    done;
    Stdio.printf "  size %-3d : mean %d nodes, worst %d, %.2fs for %d draws\n%!"
      size (!total / n) !worst (Unix.gettimeofday () -. t0) n)

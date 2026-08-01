(* Smoke-test the calculator challenge on its own. Adding it straight to
   a 100-run sweep at count=1e6 was the mistake: two runs sat for half
   an hour with nothing to show, and there was no way to tell "slow" from
   "never finds anything". *)
open Base
module G = Base_quickcheck.Generator

type expr = Lit of int | Add of expr * expr | Div of expr * expr

let rec render = function
  | Lit n -> Int.to_string n
  | Add (a, b) -> Printf.sprintf "('+', %s, %s)" (render a) (render b)
  | Div (a, b) -> Printf.sprintf "('/', %s, %s)" (render a) (render b)

let rec div_subterms = function
  | Lit _ -> true
  | Div (_, Lit 0) -> false
  | Add (a, b) | Div (a, b) -> div_subterms a && div_subterms b

let rec evaluate = function
  | Lit n -> n
  | Add (a, b) -> evaluate a + evaluate b
  | Div (a, b) -> evaluate a / evaluate b

let gen =
  G.recursive_union
    [ G.map G.int ~f:(fun n -> Lit n) ]
    ~f:(fun self ->
      [ G.map (G.both self self) ~f:(fun (a, b) -> Add (a, b))
      ; G.map (G.both self self) ~f:(fun (a, b) -> Div (a, b))
      ])

let test e =
  if not (div_subterms e) then raise Tape_stats.Invalid_example;
  match evaluate e with
  | (_ : int) -> true
  | exception Division_by_zero -> false

let () =
  List.iter [ (4, 20_000); (6, 20_000); (8, 20_000); (10, 20_000) ]
    ~f:(fun (size, count) ->
    let t0 = Unix.gettimeofday () in
    let found = ref 0 and hits = ref 0 and att = ref 0 in
    for t = 0 to 9 do
      match Tape_engine.run gen ~test ~seed:(t * 7919) ~count ~size
              ~budget:20_000
      with
      | Tape_engine.Passed _ -> ()
      | Tape_engine.Failed { minimal; attempts; _ } ->
        Int.incr found;
        att := !att + attempts;
        if String.equal (render minimal) "('/', 0, ('+', 0, 0))" then Int.incr hits
        else if t < 5 && size = 8 then
          Stdio.printf "      seed %d -> %s\n%!" t (render minimal)
    done;
    let dt = Unix.gettimeofday () -. t0 in
    Stdio.printf "  size %-3d : found %d/10, expected-answer %d, mean %d attempts, %.1fs\n%!"
      size !found !hits (if !found = 0 then 0 else !att / !found) dt)

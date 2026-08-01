(* Does the stock arm of demo/shrink_table.ml really shrink the SAME
   original failing example the tape arm does? The file says so; the
   tape engine has since gained edge-case-biased generation and the
   correlated-value mutation, neither of which the untaped schedule
   reproduces. *)
open Base
module G = Base_quickcheck.Generator

let cases_per_trial = 200
let size = 10

(* Verbatim from demo/shrink_table.ml *)
let find_failure gen ~test ~seed =
  let rec go case =
    if case >= cases_per_trial then None
    else begin
      let random = Splittable_random.of_int (seed + case) in
      let v = G.generate gen ~size ~random in
      if test v then go (case + 1) else Some v
    end
  in
  go 0

let compare_arm ~name ~gen ~test ~render =
  let same = ref 0 and differ = ref 0 and stock_none = ref 0 and tape_none = ref 0 in
  let example = ref None in
  for t = 0 to 99 do
    let seed = t * 1_000_003 in
    let stock = find_failure gen ~test ~seed in
    let tape =
      match Tape_engine.run gen ~test ~seed ~count:cases_per_trial ~size with
      | Tape_engine.Passed _ -> None
      | Tape_engine.Failed { original; _ } -> Some original
    in
    match stock, tape with
    | None, None -> ()
    | None, Some _ -> Int.incr stock_none
    | Some _, None -> Int.incr tape_none
    | Some a, Some b ->
      if String.equal (render a) (render b) then Int.incr same
      else begin
        Int.incr differ;
        if Option.is_none !example then
          example := Some (Printf.sprintf "seed %d: stock %s | tape %s" seed
                             (render a) (render b))
      end
  done;
  Stdio.printf "  %-34s same %3d, DIFFER %3d, stock-only %d, tape-only %d\n"
    name !same !differ !tape_none !stock_none;
  Option.iter !example ~f:(fun e -> Stdio.printf "      e.g. %s\n" e)

let show_l l = "[" ^ String.concat ~sep:";" (List.map l ~f:Int.to_string) ^ "]"

let () =
  Stdio.printf "original failing example, stock arm vs tape arm (100 seeds each):\n";
  compare_arm ~name:"int uniform, v >= 123457"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~test:(fun v -> v < 123_457) ~render:Int.to_string;
  compare_arm ~name:"pair, a + b >= 100"
    ~gen:(G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000))
    ~test:(fun (a, b) -> a + b < 100)
    ~render:(fun (a, b) -> Printf.sprintf "(%d,%d)" a b);
  compare_arm ~name:"int list, length >= 3"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~test:(fun l -> List.length l < 3) ~render:show_l;
  compare_arm ~name:"int list, sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100) ~render:show_l

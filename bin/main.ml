let docker = "/var/lib/docker/overlay2"
let ids = Hashtbl.create 100

let read_whole_file filename =
  let ch = open_in_bin filename in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch;
  s

let pread cmd =
  let inp = Unix.open_process_in cmd in
  let r = In_channel.input_lines inp in
  In_channel.close inp;
  r

let build_ids dir =
  Sys.readdir dir |> Array.to_list
  |> List.iter (fun subdir ->
         let link = dir ^ "/" ^ subdir ^ "/link" in
         if Sys.file_exists link then
           let id = read_whole_file link in
           Hashtbl.add ids id subdir)

let () = build_ids docker

let build_lowers dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter_map (fun subdir ->
         let lower = dir ^ "/" ^ subdir ^ "/lower" in
         if Sys.file_exists lower then
           let l = read_whole_file lower in
           String.split_on_char ':' l
           |> List.map (fun s ->
                  match String.split_on_char '/' s with
                  | [ "l"; id ] -> (subdir, Hashtbl.find ids id)
                  | _ -> assert false)
           |> Option.some
         else None)
  |> List.flatten

let overlays = build_lowers docker
let containers = pread "docker ps --all --quiet"

let find_layers filter =
  List.map
    (fun container ->
      pread ("docker inspect " ^ container ^ " --format '" ^ filter ^ "'")
      |> String.concat "" |> String.split_on_char ':'
      |> List.map (fun dir ->
             let split = String.split_on_char '/' dir in
             List.nth split 5))
    containers
  |> List.flatten

let lower_layers = find_layers "{{.GraphDriver.Data.LowerDir }}"
let merged_layers = find_layers "{{.GraphDriver.Data.MergedDir }}"

let () =
  let oc = Unix.open_process_out "dot -Tsvg -o overlay2map.svg" in
  let () = Printf.fprintf oc "digraph g1 {" in
  let () = Printf.fprintf oc "  layout=\"fdp\";" in
  let () = Printf.fprintf oc "  overlay=\"scale\";" in
  let () =
    List.iter
      (fun (x, y) -> Printf.fprintf oc "  \"%s\" -> \"%s\"\n" x y)
      overlays
  in
  let colour_node colour =
    List.iter (fun l -> Printf.fprintf oc "  \"%s\" [color=\"%s\"];\n" l colour)
  in
  let () = colour_node "red" lower_layers in
  let () = colour_node "green" merged_layers in
  let () = Printf.fprintf oc "}\n" in
  flush oc

let unused =
  let x, y = List.split overlays in
  let all = List.sort_uniq compare (x @ y) in
  let inuse = lower_layers @ merged_layers in
  List.filter (fun x -> not (List.mem x inuse)) all

let revids = Hashtbl.create 100
let () = Hashtbl.iter (fun id subdir -> Hashtbl.add revids subdir id) ids

let () =
  List.iter
    (fun x ->
      Printf.printf "rm -r %s/%s\nrm %s/l/%s\n" docker x docker
        (Hashtbl.find revids x))
    unused

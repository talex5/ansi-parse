type color = Black | Red | Green | Yellow | Blue | Magenta | Cyan | White

module Concrete =
struct
  type style = Bold | Faint | Italic | Underline | Blink | Inverse | Hidden
             | Strike | Fore of color | Back of color | Unknown of int

  type item = Esc of style list | Reset | Text of string
  type t = item

  let fmt_of_int = function
    | 0 -> Reset | 1 -> Bold | 2 -> Faint | 3 -> Italic | 4 -> Underline
    | 5 -> Blink | 7 -> Inverse | 8 -> Hidden | 9 -> Strike
    | x -> Unknown x

  let color_of_int = function
    | 0 -> Black | 1 -> Red     | 2 -> Green | 3 -> Yellow
    | 4 -> Blue  | 5 -> Magenta | 6 -> Cyan  | 7 -> White
    | _ -> assert false

  let style_of_int = function
    | x when 30 <= x && x <= 37 -> Fore (color_of_int (x-30))
    | x when 40 <= x && x <= 47 -> Back (color_of_int (x-40))
    | x                         -> fmt_of_int x

  (* val extract_esc : int list -> style list * int list *)
  let rec extract_esc = function
    | 0 :: ints -> ([], ints)
    | x :: ints -> let styles, rest = extract_esc ints in (style_of_int x :: styles, rest)

  (* val extract_item : int list -> item list * int list *)
  let extract_item = function
    | 0 :: ints -> (Reset, ints)
    | ints      -> let styles, rest = extract_esc ints in (Esc styles, rest)

  (* val items_of_ints : int list -> item list *)
  let rec items_of_ints ints =
    let item, ints' = extract_item ints in
    match ints' with
      | _ :: _ -> item :: items_of_ints ints'
      | []     -> []

  (* Grammar:
     Item --> Escape | Text
     Escape --> csi Styles? cst
     Styles --> Style ( ';' Style )*
     Style --> dig+
     Text --> [not start of csi]*
  *)
  let open Angstrom in
    let style = take_while1 (function '0' .. '9' -> true | _ -> false) >>| int_of_string

    let styles = sep_by (char ';') style

    let csi_str = "\x1b["
    let csi = string csi_str

    let cst = string "m"

    let text = peek_char >>= function
      | Some _ -> take_till (fun c -> c = csi_str.[0]) >>| fun str -> Text str
      | None   -> fail "End of input"

    let escape = csi *> styles <* cst >>| items_of_ints

    let item = (escape <|> text)

    (* val parse : Lwt_io.input_channel -> style list Lwt.t *)
    let open Angstrom_lwt_unix in
    let parse in_channel =
      parse (many item) in_channel >>= function
        | Ok cstyles -> Lwt.return cstyles
        | Error err -> Lwt.fail_with err
  end
end

module Abstract =
struct
  type weight = Normal | Bold | Faint
  type style = { weight     : weight
               ; italic     : bool
               ; underline  : bool
               ; blink      : bool
               ; reverse    : bool
               ; strike     : bool
               ; foreground : color option
               ; background : color option
               }
  type 'a t = Base of 'a | Styled of style * 'a t list

  let default = { weight     = Normal
                ; italic     = false
                ; underline  = false
                ; blink      = false
                ; reverse    = false
                ; strike     = false
                ; foreground = None
                ; background = None
                }

end

(* Apply the concrete style to the abstract style *)
let module C = Concrete
let module A = Abstract

(* apply_single : C.style -> A.style -> A.style *)
let apply_single cstyle astyle = match cstyle with
  | C.Reset     -> A.default
  | C.Bold      -> { astyle with weight = A.Bold }
  | C.Faint     -> { astyle with weight = A.Faint }
  | C.Italic    -> { astyle with italic = true }
  | C.Underline -> { astyle with underline = true }
  | C.Blink     -> { astyle with blink = true }
  | C.Inverse   -> { astyle with reverse = true }
  | C.Hidden    -> astyle (* Ignore for now... *)
  | C.Strike    -> { astyle with strike = true }
  | C.Fore col  -> { astyle with foreground = Some col }
  | C.Back col  -> { astyle with background = Some col }
  | Unknown _   -> astyle (* Ignore *)

(* val apply_multi : C.style list -> A.style -> A.style *)
let apply_multi cstyles astyle = List.fold_left (fun x y -> apply_single y x) astyle cstyles

(* val apply_root : C.item list -> A.t list *)
let rec apply_root = function
  | C.Reset :: items -> apply_root items
  | C.Text str :: items -> A.Base str :: apply_root items
  | C.Esc styles :: items -> let nodes, items' = branch items in
                             A.Styled (apply_multi styles A.default, nodes) :: apply_root items'

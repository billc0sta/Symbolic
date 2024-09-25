type expr =
  | FloatLit of float
  | Binary of expr * Lexer.token * expr
  | Unary of Lexer.token * expr
  | Grouping of expr

type statement = 
  | Print of expr
  | Exprstmt of expr

type t = {
  raw: Lexer.token list;
  previous: Lexer.token;
  pos: int;
}

exception ParseError of string * Lexer.token

val make: Lexer.token list -> t
val expression: t -> expr * t
val parse: t -> statement list
val print_expr: expr -> unit
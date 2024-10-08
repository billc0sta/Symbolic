open Parser
open Value

exception RuntimeError of string * Lexer.token

type state = {return_expr: expr option; returned: bool; breaked: bool; continued: bool; call_depth: int; loop_depth: int}
type t = {env: Environment.t; raw: statement list; state: state}

let add_natives env =
	Environment.add "print" (NatFunc (256+1, ["params..."], Natives.print), true) env;
	Environment.add "input" (NatFunc (0, [], Natives.input), true) env; 
	Environment.add "clock" (NatFunc (0, [], Natives.clock), true) env;
	Environment.add "len" (NatFunc (1, ["sequence"], Natives.len), true) env;
	Environment.add "append" (NatFunc (256+2, ["sequence"; "elements..."], Natives.append), true) env;
	Environment.add "insert" (NatFunc (3, ["sequence"; "index"; "elem"], Natives.insert), true) env;
	Environment.add "extend" (NatFunc (256+2, ["sequence"; "sequences..."], Natives.extend), true) env;
	Environment.add "merge" (NatFunc (256+2, ["sequence"; "sequences..."], Natives.merge), true) env;
	Environment.add "index" (NatFunc (2, ["sequence"; "element"], Natives.index), true) env;
	Environment.add "pop" (NatFunc (256+2, ["sequence"; "indices..."], Natives.pop), true) env;
	Environment.add "remove" (NatFunc (256+2, ["sequence"; "elements..."], Natives.remove), true) env;
	Environment.add "clear" (NatFunc (1, ["sequence"], Natives.clear), true) env;
	Environment.add "count" (NatFunc (2, ["sequence"; "element"], Natives.count), true) env

let make raw = 
	let inp = {raw; env=(Environment.make ());
	state={return_expr=None; returned=false;
	breaked=false; continued=false;
	call_depth=0; loop_depth=0}} in
	add_natives inp.env;
	inp

let rec evaluate expr inp =
	match expr with
	| FloatLit fl -> Float fl
	| StringLit str -> make_rez_string str 
	| Binary (expr1, op, expr2) -> evaluate_binary expr1 expr2 op inp
	| Unary (op, expr) -> evaluate_unary op expr inp 
	| Grouping expr -> evaluate expr inp
	| IdentExpr (tk, global) -> evaluate_ident tk global inp
	| IfExpr (cond, whentrue, whenfalse) -> evaluate_ifexpr cond whentrue whenfalse inp
	| FunCall (target, arglist, tk) -> evaluate_funcall target arglist tk inp
	| LambdaExpr (exprs, body, _) -> evaluate_lambda exprs body
	| ArrExpr (exprs, _) -> evaluate_arr exprs inp
	| Subscript (expr, subexpr, tk) -> evaluate_subscript expr subexpr tk inp
	| Range (_, tk, _, _, _) -> raise (RuntimeError ("Cannot evaluate range expression in this context", tk))
	| NilExpr -> Nil

and ev_subexpr expr tk inp =
	let ev = evaluate expr inp in
	match ev with 
	| Float fl -> begin
		if Float.trunc fl <> fl then
			raise (RuntimeError ("Cannot subscript with floating-point number", tk))
		else if fl < 0.0 && fl <> Float.neg_infinity then
			raise (RuntimeError ("Cannot subscript with a negative number", tk))
		else fl 
	end 
	| _ -> raise (RuntimeError (("Cannot subscript with value of type '"^nameof ev^"'"), tk))
	
and evaluate_subscript expr subexpr tk inp =

	match subexpr with
	| (expr1, Some expr2) -> begin
		let beginning = ev_subexpr expr1 tk inp in
		let ending    = ev_subexpr expr2 tk inp in
		let ev = evaluate expr inp in
		match ev with
		| Arr rez -> begin
			let beginning = if beginning = Float.neg_infinity then 0 else int_of_float beginning in
			let ending    = if ending = Float.infinity then Resizable.len rez else int_of_float ending in
			
			try Arr (Resizable.range rez beginning ending)
			with Invalid_argument _ -> raise (RuntimeError ("Accessing array out of bounds", tk))
		end
		| String rez -> begin
			let beginning = if beginning = Float.neg_infinity then 0 else int_of_float beginning in
			let ending    = if ending = Float.infinity then Resizable.len rez else int_of_float ending in
			
			try String (Resizable.range rez beginning ending)
			with Invalid_argument _ -> raise (RuntimeError ("Accessing string out of bounds", tk))
		end
		| _ -> raise (RuntimeError (("Value of type '"^nameof ev^"' is not subscriptable"), tk))
	end

	| (subexpr, None) -> begin
		let subscript = (ev_subexpr subexpr tk inp) in
		let subscript = if subscript = Float.neg_infinity then 0 else int_of_float subscript in
		let ev = evaluate expr inp in
		match ev with
		| Arr rez -> begin
			try Resizable.get rez subscript
			with Invalid_argument _ -> raise (RuntimeError ("Accessing array out of bounds", tk))
		end
		| String rez -> begin
			try make_rez_string (Char.escaped (Resizable.get rez subscript))
			with Invalid_argument _ -> raise (RuntimeError ("Accessing string out of bounds", tk))
		end
		| _ -> raise (RuntimeError (("Value of type '"^nameof ev^"' is not subscriptable"), tk))
	end

and evaluate_arr exprs inp = 
	let arr = Resizable.make () in
	List.iter (fun expr -> Resizable.append arr (evaluate expr inp)) exprs;
	(Arr arr)

and evaluate_lambda exprs body = 
	let rec aux acc exprs =
		match exprs with
		| [] -> (acc)
		| x::xs -> begin 
			match x with
			| IdentExpr (tk, global) -> 
				if global then raise (RuntimeError ("invalid parameter", tk))
				else aux (tk.value::acc) xs
			| _ -> assert false;
		end
	in
	let params = List.rev (aux [] exprs) in
	Func (params, body)

and evaluate_funcall target arglist tk inp =
	let lambda = evaluate target inp in
	match lambda with
	| Func (params, body) -> evaluate_func arglist params body tk inp
	| NatFunc (paramc, _, func) -> evaluate_natfunc paramc arglist func tk inp
	| _ -> assert false;

and evaluate_func arglist params body tk inp =
	let param_len = List.length params in
	let arg_len   = List.length arglist in
	if param_len <> arg_len then
		raise (RuntimeError ("The number of arguments do not match the number of parameters", tk))
	else 
		let inp = 
		{inp with env=Environment.child_of inp.env; state={inp.state with call_depth=inp.state.call_depth+1; loop_depth=0}} in
			List.iter2 (fun arg param -> 
				let value = evaluate arg inp in
				Environment.add param (value, true) inp.env
			) arglist params;
		match body with
		| Block block -> begin 
			let inp = block_stmt block inp in
			match inp.state.return_expr with
			| Some expr -> evaluate expr inp
			| None -> Nil
		end 
		| _ -> assert false;

and evaluate_natfunc paramc arglist func tk inp =
	let arg_len   = List.length arglist in
	let param_len = paramc in
	if not (param_len = arg_len || param_len >= 256 && arg_len >= (param_len - 256)) then
		raise (RuntimeError ("The number of arguments do not match the number of parameters", tk))
	else
		let val_list = List.map (fun expr -> evaluate expr inp) arglist in
		try func val_list
		with Invalid_argument message -> raise (RuntimeError (message, tk))

and evaluate_binary expr1 expr2 op inp =
	let raise_error =  (fun ev1 ev2 -> raise (RuntimeError 
		("Cannot apply operator '"^Lexer.nameof op.typeof^"' to values of types ('"^nameof ev1^"' and '"^nameof ev2^"')", op))) in
	let ev_both = (fun expr1 expr2 -> (evaluate expr1 inp, evaluate expr2 inp)) in
	let simple_binary = (fun expr1 expr2 op -> let (ev1, ev2) = ev_both expr1 expr2 in
		match (ev1, ev2) with Float fl1, Float fl2 -> (op fl1 fl2) | _ -> raise_error ev1 ev2)
	in
	match op.typeof with
	| Plus -> begin
		let (ev1, ev2) = ev_both expr1 expr2 in
		match (ev1, ev2) with
		| Float fl1, Float fl2 -> Float (fl1 +. fl2)
		| String str1, String str2 -> String (Resizable.merge str1 str2)
		| Arr arr1, Arr arr2 -> Arr (Resizable.merge arr1 arr2)
		| _ -> raise_error ev1 ev2
		end
	| EqualEqual -> begin
		let (ev1, ev2) = (ev_both expr1 expr2) in 
		match (ev1, ev2) with
		| String str1, String str2 -> Bool (str1 = str2)
		| Float fl1, Float fl2 -> Bool (fl1 = fl2)
		| Bool b1, Bool b2 -> Bool (b1 = b2)
		| Arr arr1, Arr arr2 -> Bool (arr1.arr = arr2.arr) 
		| _ -> raise_error ev1 ev2 
	end 
	| ExcEqual -> begin
		let (ev1, ev2) = (ev_both expr1 expr2) in 
		match (ev1, ev2) with
		| String str1, String str2 -> Bool (str1 <> str2)
		| Float fl1, Float fl2 -> Bool (fl1 <> fl2)
		| Bool b1, Bool b2 -> Bool (b1 <> b2)
		| Arr arr1, Arr arr2 -> Bool (arr1 <> arr2) 
		| _ -> raise_error ev1 ev2
	end
	| Minus -> Float (simple_binary expr1 expr2 (-.))
	| Star -> Float (simple_binary expr1 expr2 ( *. ))
	| Slash -> Float (simple_binary expr1 expr2 (/.))
	| Modulo -> Float (simple_binary expr1 expr2 (fun a b -> a -. (b *. (floor (a /. b)))))
	| Greater -> Bool (simple_binary expr1 expr2 (>))
	| Lesser -> Bool (simple_binary expr1 expr2 (<))
	| GreatEqual -> Bool (simple_binary expr1 expr2 (>=))
	| LessEqual -> Bool (simple_binary expr1 expr2 (<=))
	| Ampersands -> 
		let ev1 = evaluate expr1 inp in
		if truth ev1 then evaluate expr2 inp else ev1
	| Columns -> 
		let ev1 = evaluate expr1 inp in
		if truth ev1 then ev1 else evaluate expr2 inp
	| Equal | ConEqual -> assignment expr1 expr2 op inp
	| _ -> assert false

and evaluate_unary op expr inp =
	let raise_error = (fun ev -> raise (RuntimeError 
		("Cannot apply operator '"^Lexer.nameof op.typeof^"' to values of type '"^nameof ev^"'", op))) in
	let ev = evaluate expr inp in
	match op.typeof with
	| Exclamation -> Bool (not (truth ev))
	| Plus -> begin match ev with Float fl -> Float fl | _ -> raise_error ev end
	| Minus -> begin match ev with Float fl -> Float (fl*.(-1.)) | _ -> raise_error ev end
	| Tilde -> (Value.make_rez_string (nameof ev))
	| At -> (Value.make_rez_string (Value.stringify ev))
	| _ -> assert false;

and evaluate_ident tk global inp =
	let rec aux env =
		match Environment.find tk.value env with
		| None -> 
			begin
				let env = 
				try Environment.parent_of env 
				with Invalid_argument _ -> raise (RuntimeError ("Unbinded variable '"^tk.value^"' was referenced", tk)) 
				in aux env
			end
		| Some (value, _) -> value

	in let env = if global then 
		try Environment.parent_of inp.env
		with Invalid_argument _ ->
			raise (RuntimeError ("Global variable '"^tk.value^"' was referenced in global scope", tk))
		else inp.env in
	aux env

and evaluate_ifexpr cond whentrue whenfalse inp =
	let ev = evaluate cond inp in
	let trued = truth (ev) in
	if trued then evaluate whentrue inp
	else evaluate whenfalse inp	

and assignment target expr token inp =
	let mut = match token.typeof with
		| Equal -> true
		| ConEqual -> false
		| _ -> assert false;
	in
 	match target with 
	| IdentExpr _ -> assign_ident mut expr target inp
	| Subscript (target, (index, None), tk) -> 
		if not mut then raise (RuntimeError ("Cannot constant-assign an index", tk))
		else assign_subscript expr target index inp
	| _ -> assert false

and assign_subscript expr target index inp =
  let (name, global, token) =
    match target with
    | IdentExpr(tk, global) -> (tk.value, global, tk)
    | _ -> assert false
  in
  let env = 
    if global then
      try Environment.parent_of inp.env
      with Invalid_argument _ ->
        raise (RuntimeError ("Global variable '" ^ token.value ^ "' was referenced in global scope", token))
    else inp.env
  in
  match (Environment.find name env) with
  | None -> raise (RuntimeError ("Unbound variable '" ^ token.value ^ "' was referenced", token))
  | Some (arr, mut) ->
    if not mut then raise (RuntimeError ("Cannot re-assign to a constant", token))
    else
      match arr with
      | Arr rez ->
        let index = int_of_float (ev_subexpr index token inp) in
        let value = evaluate expr inp in
        begin
          try Resizable.putat rez index value; value
          with Invalid_argument _ ->
            raise (RuntimeError ("Accessing array out of bounds", token))
        end
      | String rez ->
        let index = int_of_float (ev_subexpr index token inp) in
        let value = evaluate expr inp in
        begin
          match value with
          | String chr ->
            let length = Resizable.len chr in
            if length <> 1 then
              raise (RuntimeError ("Assigning invalid character count value to a string index", token))
            else
            	begin
              try Resizable.putat rez index (Resizable.get chr 0); value
              with Invalid_argument _ ->
                raise (RuntimeError ("Accessing array out of bounds", token))
          		end
          | _ ->
            raise (RuntimeError ("Cannot assign to a string index with value of type '" ^ nameof value ^ "'", token))
        end
      | _ -> raise (RuntimeError (("Value of type '"^nameof arr^"' is not subscriptable"), token))

and assign_ident ismut expr ident inp =
	let (name, global, token) = 
	match ident with
	| IdentExpr(tk, global) -> (tk.value, global, tk)
	| _ -> assert false;
	in 
	let env = if global then
		try Environment.parent_of inp.env
		with Invalid_argument _ -> 
			raise (RuntimeError ("Global variable '"^token.value^"' was referenced in global scope", token))
		else inp.env 
	in
	match (Environment.find name env) with
	| None -> begin
		let value = evaluate expr inp in
		Environment.add name (value, ismut) env; value
	end
	| Some (_, mut) -> begin 
		if not mut then raise (RuntimeError ("Cannot re-assign to a constant", token))
		else 
		let value = evaluate expr inp in
		Environment.replace name (value, ismut) env; value
	end

and exec_stmt stmt inp =
		match stmt with
	| Exprstmt expr -> ignore (evaluate expr inp); inp
	| IfStmt (cond, whentrue, whenfalse) -> if_stmt cond whentrue whenfalse inp
	| Block stmts -> block_stmt stmts inp
	| LoopStmt (cond, stmt) -> loop_stmt cond stmt inp
	| Break tk -> break_stmt tk inp
	| Continue tk -> continue_stmt tk inp
	| NoOp _ -> inp
	| Return (expr, tk) -> return_stmt expr tk inp

and break_stmt tk inp =
		if inp.state.loop_depth = 0 then raise (RuntimeError ("Break statement ('**') outside of loop", tk))
		else {inp with state={inp.state with breaked = true}}

and continue_stmt tk inp =
		if inp.state.loop_depth = 0 then raise (RuntimeError ("Continue statement ('<<') outside of loop", tk))
		else {inp with state={inp.state with continued = true}}

and return_stmt expr tk inp =
		if inp.state.call_depth = 0 then raise (RuntimeError ("Return statement ('->') outside of function", tk))
		else {inp with state={inp.state with returned = true; return_expr = Some expr}}

and block_stmt stmts inp =
	let rec aux stmts inp =
		match stmts with
		| [] -> inp
		| x::xs -> begin
			let inp = exec_stmt x inp in
			if inp.state.returned || inp.state.continued || inp.state.breaked 
			then inp
			else aux xs inp
		end
	in aux stmts inp

and if_stmt cond whentrue whenfalse inp =
	if truth (evaluate cond inp) then exec_stmt whentrue inp 
	else match whenfalse with
	| None -> inp
	| Some block -> exec_stmt block inp

and loop_stmt cond stmt inp =
	let inp = {inp with state={inp.state with loop_depth=inp.state.loop_depth+1}} in
	match cond with
	| Range _ -> range_loop cond stmt inp
	| _ -> normal_loop cond stmt inp
    
and range_loop range stmt inp =
	let (cond, name, beg, dir) = start_range range inp in
	let (beg, dir) = (float_of_int beg, float_of_int dir) in
	let rec aux iter inp =
		if truth (evaluate cond inp) then
			let inp = exec_stmt stmt inp in
			let iter = iter+.dir in
			Environment.replace name (Float (iter), true) inp.env;
			if inp.state.breaked then {inp with state={inp.state with breaked=false}}
			else if inp.state.continued then aux iter {inp with state={inp.state with continued=false}}
			else aux iter inp
		else inp
	in 
	let inp = aux beg inp in
	Environment.remove name inp.env;
	inp

and normal_loop cond stmt inp =
	let rec aux inp =
		if truth (evaluate cond inp) then
			let inp = exec_stmt stmt inp in
			if inp.state.breaked then {inp with state={inp.state with breaked=false}}
			else if inp.state.continued then aux {inp with state={inp.state with continued=false}}
			else aux inp
		else inp
	in aux inp

and start_range range inp =

	let (expr1, tk1, ident, tk2, expr2) = match range with
	| Range (expr1, tk1, ident, tk2, expr2) -> (expr1, tk1, ident, tk2, expr2) 
	| _ -> assert false;
	in

	let ev_expr expr = 
		match evaluate expr inp with
		| Float fl -> 
			if Float.trunc fl <> fl 
			then raise (RuntimeError ("Cannot use floating-point number in range expression", tk1))
			else int_of_float fl
		| ev ->  
			raise (RuntimeError (("Cannot use value of type '"^Value.nameof ev^"' in range expression"), tk1))
	in

	let (beg, dir) = 
		match tk1.typeof with
		| Greater    -> ((ev_expr expr1)-1, -1)
		| GreatEqual -> ((ev_expr expr1),   -1)
		| Lesser     -> ((ev_expr expr1)+1,  1)
		| LessEqual  -> ((ev_expr expr1),    1)
		| _ -> assert false;
	in
	let endof =
		match tk2.typeof with
		| Greater | Lesser | LessEqual | GreatEqual -> (ev_expr expr2)
		| _ -> assert false;
	in
	let () = if dir = 1 && not (beg < endof) then
		raise (RuntimeError ("Beginning should be less than ending of range expression", tk1))
		else if dir = -1 && not (beg > endof) then
		raise (RuntimeError ("Beginning should be greter than ending of range expression", tk1))
		else ()
	in
	let name = match ident with IdentExpr (tk, _) -> tk.value | _ -> assert false; in
	Environment.add name (Float (float_of_int beg), true) inp.env;
	(Binary (ident, tk2, FloatLit (float_of_int endof)), name, beg, dir)

let run inp = ignore (exec_stmt (Block inp.raw) inp)
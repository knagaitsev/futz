{
module Futz.Parser where
import Futz.Lexer
import qualified Futz.Types as T
import Futz.Syntax
}

%name parseFutz
%tokentype { Token }
%error { parseError }

%token

    -- Match syntax
    let  { Tok _ LSyntax "let" }
    in   { Tok _ LSyntax "in" }
    of   { Tok _ LSyntax "of" }
    if   { Tok _ LSyntax "if" }
    then { Tok _ LSyntax "then" }
    else { Tok _ LSyntax "else" }
    data { Tok _ LSyntax "data" }

    pipe   { Tok _ LPipe _ }

    -- Literals
    int  { Tok _ LInt $$ }
    var  { Tok _ LSym $$ }
    op   { Tok _ LOp $$ }
    -- Symbols
    '='      { Tok _ LEq  _}
    -- '+'      { Tok _ LPlus _ }
    -- '-'      { Tok _ LMinus _ }
    -- '*'      { Tok _ LTimes _ }
    -- '/'      { Tok _ LDiv _ }
    '('      { Tok _ LLParen _ }
    ')'      { Tok _ LRParen _ }
    arr      { Tok _ LArrow _ }
    'λ'      { Tok _ LLambda _ }
    tname    { Tok _ LType $$ }
    tvar     { Tok _ LTypeVar $$ }
    "::"     { Tok _ LIsType _ }
    -- Magic stuff inserted by the tokenizer
    sol      { TStartOfLine }

%right APP

-- %left arr
-- %right in
-- %nonassoc '>' '<'
-- %left '+' '-'
-- %left '*' '/'
%left NEG



%%

toplevel : statement            { [$1] }
         | statement toplevel   { $1 : $2 }

statement
  : sol var "::" type           { TypeDecl $2 $4 }
  | sol '(' op ')' "::" type    { TypeDecl $3 $6 }
  | sol var '=' exp             { Decl $2 $4 }
  | sol '(' op ')' '=' exp      { Decl $3 $6 }
  | sol data tname listof(tvar) '=' ctors     { DataDecl $3 $4 $6 }
  -- | sol var args '=' exp        { Decl $2 (expandLambdaArguments $3 $5) }

exp
  : let var '=' exp in exp                 { Let $2 $4 $6 }
  | if exp then exp else exp               { IfElse $2 $4 $6 }
  -- | let var args '=' exp in exp            { Let $2 (expandLambdaArguments $3 $5) $7 }
  | 'λ' unmatching_args arr exp            { expandLambdaArguments $2 $4 }
  | var                                    { Var $1 }
  | expapp                                 { $1 }
  | atom of exp                            { App $1 $3 }
  | atom op exp                            { Inf $2 $1 $3 }
  | atom                                   { $1 }
  | op                                     { Var $1 }

expapp
  : expapp atom                   { App $1 $2 }
  | atom                          { $1 }


atom
  : literal                       { Lit $1 }
  | var                           { Var $1 }
  | '(' op ')'                             { Var $2 }
  | '(' exp ')'                   { $2 }


literal
  : int                           { LitInt (read $1) }

argument : var                    { Named $1 }

-- TODO: argument 
args : argument                   { [$1] }
     | argument args              { $1 : $2 }



unmatching_args : var                   { [$1] }
                | var unmatching_args   { $1 : $2 }


typeParameters : simpleType                   { [$1] }
               | simpleType typeParameters    { $1 : $2 }


-- A simpleType is a type that is either a single name, or
-- a complex type wrapped in parens
-- (arrows are not simple types)
simpleType : tname                { T.TCon (T.Tycon $1 T.Star) } 
           | tvar                 { T.TVar (T.Tyvar (tail $1) T.Star) }
           | '(' type ')'         { $2 }

type : simpleType                 { $1 } -- T.TCon (T.Tycon $1 T.Star) }
     | tApp                       { $1 }
     | type arr type              { T.fn $1 $3 }


tApp : simpleType                 { $1 }
     | tApp simpleType            { T.TAp $1 $2 }


ctor : tname listof(simpleType)   { Constructor $1 $2 }
     | tname                      { Constructor $1 [] }

ctors : ctor                      { [$1] }
      | ctor pipe ctors           { $1 : $3 }


listof(p) : p                   { [$1] }
          | p listof(p)         { $1 : $2 }

{

parseError :: [Token] -> a
parseError ((Tok (Pos line col) tc raw):ts)
  = error $ "Parse error near '" <> raw <> "' at line " <> (show line) <> " column " <> (show col)
parseError e = error $ "Unexplained parse error: " <> (show e)

expandLambdaArguments :: [String] -> Exp -> Exp
expandLambdaArguments (x:[]) body = Lambda x body
expandLambdaArguments (x:xs) body = Lambda x (expandLambdaArguments xs body)

}

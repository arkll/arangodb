%define api.pure
%name-prefix "Aql"
%locations 
%defines
%parse-param { arangodb::aql::Parser* parser }
%lex-param { void* scanner } 
%error-verbose

%{
#include "Aql/AstNode.h"
#include "Aql/CollectNode.h"
#include "Aql/Function.h"
#include "Aql/Parser.h"
#include "Aql/Quantifier.h"
#include "Basics/conversions.h"
#include "Basics/tri-strings.h"
%}

%union {
  arangodb::aql::AstNode*  node;
  struct {
    char*                  value;
    size_t                 length;
  }                        strval;
  bool                     boolval;
  int64_t                  intval;
}

%{

using namespace arangodb::aql;

////////////////////////////////////////////////////////////////////////////////
/// @brief shortcut macro for signaling out of memory
////////////////////////////////////////////////////////////////////////////////

#define ABORT_OOM                                   \
  parser->registerError(TRI_ERROR_OUT_OF_MEMORY);   \
  YYABORT;

#define scanner parser->scanner()

////////////////////////////////////////////////////////////////////////////////
/// @brief forward for lexer function defined in Aql/tokens.ll
////////////////////////////////////////////////////////////////////////////////

int Aqllex (YYSTYPE*, 
            YYLTYPE*, 
            void*);
 
////////////////////////////////////////////////////////////////////////////////
/// @brief register parse error
////////////////////////////////////////////////////////////////////////////////

void Aqlerror (YYLTYPE* locp, 
               arangodb::aql::Parser* parser,
               char const* message) {
  parser->registerParseError(TRI_ERROR_QUERY_PARSE, message, locp->first_line, locp->first_column);
}

////////////////////////////////////////////////////////////////////////////////
/// @brief check if any of the variables used in the INTO expression were 
/// introduced by the COLLECT itself, in which case it would fail
////////////////////////////////////////////////////////////////////////////////
         
static Variable const* CheckIntoVariables(AstNode const* collectVars, 
                                          std::unordered_set<Variable const*> const& vars) {
  if (collectVars == nullptr || collectVars->type != NODE_TYPE_ARRAY) {
    return nullptr;
  }

  size_t const n = collectVars->numMembers();
  for (size_t i = 0; i < n; ++i) {
    auto member = collectVars->getMember(i);

    if (member != nullptr) {
      TRI_ASSERT(member->type == NODE_TYPE_ASSIGN);
      auto v = static_cast<Variable*>(member->getMember(0)->getData());
      if (vars.find(v) != vars.end()) {
        return v;
      }
    }
  }

  return nullptr;
}

////////////////////////////////////////////////////////////////////////////////
/// @brief register variables in the scope
////////////////////////////////////////////////////////////////////////////////

static void RegisterAssignVariables(arangodb::aql::Scopes* scopes, AstNode const* vars) { 
  size_t const n = vars->numMembers();
  for (size_t i = 0; i < n; ++i) {
    auto member = vars->getMember(i);

    if (member != nullptr) {
      TRI_ASSERT(member->type == NODE_TYPE_ASSIGN);
      auto v = static_cast<Variable*>(member->getMember(0)->getData());
      scopes->addVariable(v);
    }
  }
}

////////////////////////////////////////////////////////////////////////////////
/// @brief validate the aggregate variables expressions
////////////////////////////////////////////////////////////////////////////////

static bool ValidateAggregates(Parser* parser, AstNode const* aggregates) {
  size_t const n = aggregates->numMembers();

  for (size_t i = 0; i < n; ++i) {
    auto member = aggregates->getMember(i);

    if (member != nullptr) {
      TRI_ASSERT(member->type == NODE_TYPE_ASSIGN);
      auto func = member->getMember(1);

      bool isValid = true;
      if (func->type != NODE_TYPE_FCALL) {
        // aggregate expression must be a function call
        isValid = false;
      }
      else {
        auto f = static_cast<arangodb::aql::Function*>(func->getData());
        if (! Aggregator::isSupported(f->externalName)) {
          // aggregate expression must be a call to MIN|MAX|LENGTH...
          isValid = false;
        }
      }

      if (! isValid) {
        parser->registerError(TRI_ERROR_QUERY_INVALID_AGGREGATE_EXPRESSION);
        return false;
      }
    }
  }

  return true;
}

////////////////////////////////////////////////////////////////////////////////
/// @brief start a new scope for the collect
////////////////////////////////////////////////////////////////////////////////

static bool StartCollectScope(arangodb::aql::Scopes* scopes) { 
  // check if we are in the main scope
  if (scopes->type() == arangodb::aql::AQL_SCOPE_MAIN) {
    return false;
  } 

  // end the active scopes
  scopes->endNested();
  // start a new scope
  scopes->start(arangodb::aql::AQL_SCOPE_COLLECT);
  return true;
}

////////////////////////////////////////////////////////////////////////////////
/// @brief get the INTO variable stored in a node (may not exist)
////////////////////////////////////////////////////////////////////////////////

static AstNode const* GetIntoVariable(Parser* parser, AstNode const* node) {
  if (node == nullptr) {
    return nullptr;
  }

  if (node->type == NODE_TYPE_VALUE) {
    // node is a string containing the variable name
    return parser->ast()->createNodeVariable(node->getStringValue(), node->getStringLength(), true);
  }

  // node is an array with the variable name as the first member
  TRI_ASSERT(node->type == NODE_TYPE_ARRAY);
  TRI_ASSERT(node->numMembers() == 2);

  auto v = node->getMember(0);
  TRI_ASSERT(v->type == NODE_TYPE_VALUE);
  return parser->ast()->createNodeVariable(v->getStringValue(), v->getStringLength(), true);
}

////////////////////////////////////////////////////////////////////////////////
/// @brief get the INTO variable = expression stored in a node (may not exist)
////////////////////////////////////////////////////////////////////////////////

static AstNode const* GetIntoExpression(AstNode const* node) {
  if (node == nullptr || node->type == NODE_TYPE_VALUE) {
    return nullptr;
  }

  // node is an array with the expression as the second member
  TRI_ASSERT(node->type == NODE_TYPE_ARRAY);
  TRI_ASSERT(node->numMembers() == 2);

  return node->getMember(1);
}

%}

/* define tokens and "nice" token names */
%token T_FOR "FOR declaration"
%token T_LET "LET declaration" 
%token T_FILTER "FILTER declaration" 
%token T_RETURN "RETURN declaration" 
%token T_COLLECT "COLLECT declaration" 
%token T_SORT "SORT declaration" 
%token T_LIMIT "LIMIT declaration"

%token T_ASC "ASC keyword"
%token T_DESC "DESC keyword"
%token T_IN "IN keyword"
%token T_WITH "WITH keyword"
%token T_INTO "INTO keyword"
%token T_AGGREGATE "AGGREGATE keyword"

%token T_GRAPH "GRAPH keyword"
%token T_SHORTEST_PATH "SHORTEST_PATH keyword"
%token T_DISTINCT "DISTINCT modifier"

%token T_REMOVE "REMOVE command"
%token T_INSERT "INSERT command"
%token T_UPDATE "UPDATE command"
%token T_REPLACE "REPLACE command"
%token T_UPSERT "UPSERT command"

%token T_NULL "null" 
%token T_TRUE "true" 
%token T_FALSE "false"
%token T_STRING "identifier" 
%token T_QUOTED_STRING "quoted string" 
%token T_INTEGER "integer number" 
%token T_DOUBLE "number" 
%token T_PARAMETER "bind parameter"

%token T_ASSIGN "assignment"

%token T_NOT "not operator"
%token T_AND "and operator"
%token T_OR "or operator"
%token T_NIN "not in operator"

%token T_REGEX_MATCH "~= operator"
%token T_REGEX_NON_MATCH "~! operator"

%token T_EQ "== operator"
%token T_NE "!= operator"
%token T_LT "< operator"
%token T_GT "> operator"
%token T_LE "<= operator"
%token T_GE ">= operator"

%token T_LIKE "like operator"

%token T_PLUS "+ operator"
%token T_MINUS "- operator"
%token T_TIMES "* operator"
%token T_DIV "/ operator"
%token T_MOD "% operator"

%token T_QUESTION "?"
%token T_COLON ":"
%token T_SCOPE "::"
%token T_RANGE ".."

%token T_COMMA ","
%token T_OPEN "("
%token T_CLOSE ")"
%token T_OBJECT_OPEN "{"
%token T_OBJECT_CLOSE "}"
%token T_ARRAY_OPEN "["
%token T_ARRAY_CLOSE "]"

%token T_END 0 "end of query string"

%token T_OUTBOUND "outbound modifier"
%token T_INBOUND "inbound modifier"

%token T_ANY "any modifier"
%token T_ALL "all modifier"
%token T_NONE "none modifier"

/* define operator precedence */
%left T_COMMA
%left T_DISTINCT
%right T_QUESTION T_COLON
%right T_ASSIGN
%left T_WITH
%nonassoc T_INTO
%left T_OR 
%left T_AND
%nonassoc T_OUTBOUND T_INBOUND T_ANY T_ALL T_NONE
%left T_EQ T_NE T_LIKE T_REGEX_MATCH T_REGEX_NON_MATCH 
%left T_IN T_NIN 
%left T_LT T_GT T_LE T_GE
%left T_RANGE
%left T_PLUS T_MINUS
%left T_TIMES T_DIV T_MOD
%right UMINUS UPLUS T_NOT
%left FUNCCALL
%left REFERENCE
%left INDEXED
%left EXPANSION
%left T_SCOPE

/* define token return types */
%type <strval> T_STRING
%type <strval> T_QUOTED_STRING
%type <node> T_INTEGER
%type <node> T_DOUBLE
%type <strval> T_PARAMETER; 
%type <node> with_collection;
%type <node> sort_list;
%type <node> sort_element;
%type <node> sort_direction;
%type <node> collect_list;
%type <node> collect_element;
%type <node> collect_variable_list;
%type <node> keep;
%type <node> aggregate;
%type <node> collect_optional_into;
%type <strval> count_into;
%type <node> expression;
%type <node> expression_or_query;
%type <node> distinct_expression;
%type <node> operator_unary;
%type <node> operator_binary;
%type <node> operator_ternary;
%type <node> function_call;
%type <strval> function_name;
%type <node> optional_function_call_arguments;
%type <node> function_arguments_list;
%type <node> compound_value;
%type <node> array;
%type <node> optional_array_elements;
%type <node> array_elements_list;
%type <node> object;
%type <node> options;
%type <node> optional_object_elements;
%type <node> object_elements_list;
%type <node> object_element;
%type <strval> object_element_name;
%type <intval> array_filter_operator;
%type <node> optional_array_filter;
%type <node> optional_array_limit;
%type <node> optional_array_return;
%type <node> graph_subject;
%type <intval> graph_direction;
%type <node> graph_direction_steps;
%type <node> graph_collection;
%type <node> reference;
%type <node> simple_value;
%type <node> value_literal;
%type <node> collection_name;
%type <node> in_or_into_collection;
%type <node> bind_parameter;
%type <strval> variable_name;
%type <node> numeric_value;
%type <intval> update_or_replace;
%type <node> quantifier;


/* define start token of language */
%start queryStart

%%

with_collection:
    T_STRING {
      $$ = parser->ast()->createNodeValueString($1.value, $1.length);
    }
  | bind_parameter {
      char const* p = $1->getStringValue();
      size_t const len = $1->getStringLength();
      if (len < 1 || *p != '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), p, yylloc.first_line, yylloc.first_column);
      }
      $$ = $1;
    }
  ;

with_collection_list:
     with_collection {
       auto node = static_cast<AstNode*>(parser->peekStack());
       node->addMember($1);
     }
   | with_collection_list T_COMMA with_collection {
       auto node = static_cast<AstNode*>(parser->peekStack());
       node->addMember($3);
     }
   | with_collection_list with_collection {
       auto node = static_cast<AstNode*>(parser->peekStack());
       node->addMember($2);
     }
   ;

optional_with:
     /* empty */ {
     }
   | T_WITH {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
     } with_collection_list {
      auto node = static_cast<AstNode*>(parser->popStack());
      auto withNode = parser->ast()->createNodeWithCollections(node);
      parser->ast()->addOperation(withNode);
     }
   ;

queryStart: 
    optional_with query {
    }
  ;

query: 
    optional_statement_block_statements final_statement {
    }
  ;

final_statement:
    return_statement {
    }
  | remove_statement {
      parser->ast()->scopes()->endNested();
    }
  | insert_statement {
      parser->ast()->scopes()->endNested();
    }
  | update_statement {
      parser->ast()->scopes()->endNested();
    }
  | replace_statement {
      parser->ast()->scopes()->endNested();
    }
  | upsert_statement {
      parser->ast()->scopes()->endNested();
    }
  ;

optional_statement_block_statements:
    /* empty */ {
    }
  | optional_statement_block_statements statement_block_statement {
    }
  ;

statement_block_statement: 
    for_statement {
    }
  | let_statement {
    }
  | filter_statement {
    }
  | collect_statement {
    }
  | sort_statement {
    }
  | limit_statement {
    }
  | remove_statement {
    }
  | insert_statement {
    }
  | update_statement {
    }
  | replace_statement {
    }
  | upsert_statement {
    }
  ;

for_statement:
    T_FOR variable_name T_IN expression {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
     
      auto node = parser->ast()->createNodeFor($2.value, $2.length, $4, true);
      parser->ast()->addOperation(node);
    }
    | T_FOR traversal_statement {
    }
    | T_FOR shortest_path_statement {
    }
  ;

traversal_statement:
    variable_name T_IN graph_direction_steps expression graph_subject options {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
      auto node = parser->ast()->createNodeTraversal($1.value, $1.length, $3, $4, $5, $6);
      parser->ast()->addOperation(node);
    }
    | variable_name T_COMMA variable_name T_IN graph_direction_steps expression graph_subject options {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
      auto node = parser->ast()->createNodeTraversal($1.value, $1.length, $3.value, $3.length, $5, $6, $7, $8);
      parser->ast()->addOperation(node);
    }
    | variable_name T_COMMA variable_name T_COMMA variable_name T_IN graph_direction_steps expression graph_subject options {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
      auto node = parser->ast()->createNodeTraversal($1.value, $1.length, $3.value, $3.length, $5.value, $5.length, $7, $8, $9, $10);
      parser->ast()->addOperation(node);
    }
  ;

shortest_path_statement:
    variable_name T_IN graph_direction T_SHORTEST_PATH expression T_STRING expression graph_subject options {
      if (!TRI_CaseEqualString($6.value, "TO")) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "unexpected qualifier '%s', expecting 'TO'", $6.value, yylloc.first_line, yylloc.first_column);
      }
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
      auto node = parser->ast()->createNodeShortestPath($1.value, $1.length, $3, $5, $7, $8, $9);
      parser->ast()->addOperation(node);
    }
    | variable_name T_COMMA variable_name T_IN graph_direction T_SHORTEST_PATH expression T_STRING expression graph_subject options {
      if (!TRI_CaseEqualString($8.value, "TO")) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "unexpected qualifier '%s', expecting 'TO'", $8.value, yylloc.first_line, yylloc.first_column);
      }
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_FOR);
      auto node = parser->ast()->createNodeShortestPath($1.value, $1.length, $3.value, $3.length, $5, $7, $9, $10, $11);
      parser->ast()->addOperation(node);
    }
  ; 

filter_statement:
    T_FILTER expression {
      // operand is a reference. can use it directly
      auto node = parser->ast()->createNodeFilter($2);
      parser->ast()->addOperation(node);
    }
  ;

let_statement:
    T_LET let_list {
    }
  ;

let_list: 
    let_element {
    }
  | let_list T_COMMA let_element {
    }
  ;

let_element:
    variable_name T_ASSIGN expression {
      auto node = parser->ast()->createNodeLet($1.value, $1.length, $3, true);
      parser->ast()->addOperation(node);
    }
  ;

count_into: 
    T_WITH T_STRING T_INTO variable_name {
      if (! TRI_CaseEqualString($2.value, "COUNT")) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "unexpected qualifier '%s', expecting 'COUNT'", $2.value, yylloc.first_line, yylloc.first_column);
      }

      $$ = $4;
    }
  ;

collect_variable_list:
    T_COLLECT {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } collect_list { 
      auto list = static_cast<AstNode*>(parser->popStack());

      if (list == nullptr) {
        ABORT_OOM
      }
      $$ = list;
    }
  ;

collect_statement: 
    T_COLLECT count_into options {
      /* COLLECT WITH COUNT INTO var OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      StartCollectScope(scopes);

      auto node = parser->ast()->createNodeCollectCount(parser->ast()->createNodeArray(), $2.value, $2.length, $3);
      parser->ast()->addOperation(node);
    }
  | collect_variable_list count_into options {
      /* COLLECT var = expr WITH COUNT INTO var OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      if (StartCollectScope(scopes)) {
        RegisterAssignVariables(scopes, $1);
      }

      auto node = parser->ast()->createNodeCollectCount($1, $2.value, $2.length, $3);
      parser->ast()->addOperation(node);
    }
  | T_COLLECT aggregate collect_optional_into options {
      /* AGGREGATE var = expr OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      if (StartCollectScope(scopes)) {
        RegisterAssignVariables(scopes, $2);
      }

      // validate aggregates
      if (! ValidateAggregates(parser, $2)) {
        YYABORT;
      }

      if ($3 != nullptr && $3->type == NODE_TYPE_ARRAY) {
        std::unordered_set<Variable const*> vars;
        Ast::getReferencedVariables($3->getMember(1), vars);

        Variable const* used = CheckIntoVariables($2, vars);
        if (used != nullptr) {
          std::string msg("use of COLLECT variable '" + used->name + "' IN INTO expression");
          parser->registerParseError(TRI_ERROR_QUERY_PARSE, msg.c_str(), yylloc.first_line, yylloc.first_column);
        }
      }

      AstNode const* into = GetIntoVariable(parser, $3);
      AstNode const* intoExpression = GetIntoExpression($3);

      auto node = parser->ast()->createNodeCollect(parser->ast()->createNodeArray(), $2, into, intoExpression, nullptr, $3);
      parser->ast()->addOperation(node);
    }
  | collect_variable_list aggregate collect_optional_into options {
      /* COLLECT var = expr AGGREGATE var = expr OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      if (StartCollectScope(scopes)) {
        RegisterAssignVariables(scopes, $1);
        RegisterAssignVariables(scopes, $2);
      }

      if (! ValidateAggregates(parser, $2)) {
        YYABORT;
      }

      if ($3 != nullptr && $3->type == NODE_TYPE_ARRAY) {
        std::unordered_set<Variable const*> vars;
        Ast::getReferencedVariables($3->getMember(1), vars);

        Variable const* used = CheckIntoVariables($1, vars);
        if (used != nullptr) {
          std::string msg("use of COLLECT variable '" + used->name + "' IN INTO expression");
          parser->registerParseError(TRI_ERROR_QUERY_PARSE, msg.c_str(), yylloc.first_line, yylloc.first_column);
        }
        used = CheckIntoVariables($2, vars);
        if (used != nullptr) {
          std::string msg("use of COLLECT variable '" + used->name + "' IN INTO expression");
          parser->registerParseError(TRI_ERROR_QUERY_PARSE, msg.c_str(), yylloc.first_line, yylloc.first_column);
        }
      }

      // note all group variables
      std::unordered_set<Variable const*> groupVars;
      size_t n = $1->numMembers();
      for (size_t i = 0; i < n; ++i) {
        auto member = $1->getMember(i);

        if (member != nullptr) {
          TRI_ASSERT(member->type == NODE_TYPE_ASSIGN);
          groupVars.emplace(static_cast<Variable const*>(member->getMember(0)->getData()));
        }
      }

      // now validate if any aggregate refers to one of the group variables
      n = $2->numMembers();
      for (size_t i = 0; i < n; ++i) {
        auto member = $2->getMember(i);

        if (member != nullptr) {
          TRI_ASSERT(member->type == NODE_TYPE_ASSIGN);
          std::unordered_set<Variable const*> variablesUsed;
          Ast::getReferencedVariables(member->getMember(1), variablesUsed);

          for (auto& it : groupVars) {
            if (variablesUsed.find(it) != variablesUsed.end()) {
              parser->registerParseError(TRI_ERROR_QUERY_VARIABLE_NAME_UNKNOWN, 
                "use of unknown variable '%s' in aggregate expression", it->name.c_str(), yylloc.first_line, yylloc.first_column);
              break;
            }
          }
        }
      }

      AstNode const* into = GetIntoVariable(parser, $3);
      AstNode const* intoExpression = GetIntoExpression($3);

      auto node = parser->ast()->createNodeCollect($1, $2, into, intoExpression, nullptr, $4);
      parser->ast()->addOperation(node);
    }
  | collect_variable_list collect_optional_into options {
      /* COLLECT var = expr INTO var OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      if (StartCollectScope(scopes)) {
        RegisterAssignVariables(scopes, $1);
      }

      if ($2 != nullptr && $2->type == NODE_TYPE_ARRAY) {
        std::unordered_set<Variable const*> vars;
        Ast::getReferencedVariables($2->getMember(1), vars);

        Variable const* used = CheckIntoVariables($1, vars);
        if (used != nullptr) {
          std::string msg("use of COLLECT variable '" + used->name + "' IN INTO expression");
          parser->registerParseError(TRI_ERROR_QUERY_PARSE, msg.c_str(), yylloc.first_line, yylloc.first_column);
        }
      }

      AstNode const* into = GetIntoVariable(parser, $2);
      AstNode const* intoExpression = GetIntoExpression($2);

      auto node = parser->ast()->createNodeCollect($1, parser->ast()->createNodeArray(), into, intoExpression, nullptr, $3);
      parser->ast()->addOperation(node);
    }
  | collect_variable_list collect_optional_into keep options {
      /* COLLECT var = expr INTO var KEEP ... OPTIONS ... */
      auto scopes = parser->ast()->scopes();

      if (StartCollectScope(scopes)) {
        RegisterAssignVariables(scopes, $1);
      }

      if ($2 == nullptr && 
          $3 != nullptr) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "use of 'KEEP' without 'INTO'", yylloc.first_line, yylloc.first_column);
      }

      if ($2 != nullptr && $2->type == NODE_TYPE_ARRAY) {
        std::unordered_set<Variable const*> vars;
        Ast::getReferencedVariables($2->getMember(1), vars);

        Variable const* used = CheckIntoVariables($1, vars);
        if (used != nullptr) {
          std::string msg("use of COLLECT variable '" + used->name + "' IN INTO expression");
          parser->registerParseError(TRI_ERROR_QUERY_PARSE, msg.c_str(), yylloc.first_line, yylloc.first_column);
        }
      }
 
      AstNode const* into = GetIntoVariable(parser, $2);
      AstNode const* intoExpression = GetIntoExpression($2);

      auto node = parser->ast()->createNodeCollect($1, parser->ast()->createNodeArray(), into, intoExpression, $3, $4);
      parser->ast()->addOperation(node);
    }
  ;

collect_list: 
    collect_element {
    }
  | collect_list T_COMMA collect_element {
    }
  ;

collect_element:
    variable_name T_ASSIGN expression {
      auto node = parser->ast()->createNodeAssign($1.value, $1.length, $3);
      parser->pushArrayElement(node);
    }
  ;

collect_optional_into: 
    /* empty */ {
      $$ = nullptr;
    }
  | T_INTO variable_name {
      $$ = parser->ast()->createNodeValueString($2.value, $2.length);
    }
  | T_INTO variable_name T_ASSIGN expression {
      auto node = parser->ast()->createNodeArray();
      node->addMember(parser->ast()->createNodeValueString($2.value, $2.length));
      node->addMember($4);
      $$ = node;
    }
  ;

variable_list: 
    variable_name {
      if (! parser->ast()->scopes()->existsVariable($1.value, $1.length)) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "use of unknown variable '%s' for KEEP", $1.value, yylloc.first_line, yylloc.first_column);
      }
        
      auto node = parser->ast()->createNodeReference($1.value, $1.length);
      if (node == nullptr) {
        ABORT_OOM
      }

      // indicate the this node is a reference to the variable name, not the variable value
      node->setFlag(FLAG_KEEP_VARIABLENAME);
      parser->pushArrayElement(node);
    }
  | variable_list T_COMMA variable_name {
      if (! parser->ast()->scopes()->existsVariable($3.value, $3.length)) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "use of unknown variable '%s' for KEEP", $3.value, yylloc.first_line, yylloc.first_column);
      }
        
      auto node = parser->ast()->createNodeReference($3.value, $3.length);
      if (node == nullptr) {
        ABORT_OOM
      }

      // indicate the this node is a reference to the variable name, not the variable value
      node->setFlag(FLAG_KEEP_VARIABLENAME);
      parser->pushArrayElement(node);
    }
  ;

keep: 
    T_STRING {
      if (! TRI_CaseEqualString($1.value, "KEEP")) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "unexpected qualifier '%s', expecting 'KEEP'", $1.value, yylloc.first_line, yylloc.first_column);
      }

      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } variable_list {
      auto list = static_cast<AstNode*>(parser->popStack());
      $$ = list;
    }
  ;

aggregate: 
    T_AGGREGATE {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } collect_list {
      auto list = static_cast<AstNode*>(parser->popStack());
      $$ = list;
    }
  ;

sort_statement:
    T_SORT {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } sort_list {
      auto list = static_cast<AstNode const*>(parser->popStack());
      auto node = parser->ast()->createNodeSort(list);
      parser->ast()->addOperation(node);
    }
  ;

sort_list: 
    sort_element {
      parser->pushArrayElement($1);
    }
  | sort_list T_COMMA sort_element {
      parser->pushArrayElement($3);
    }
  ;

sort_element:
    expression sort_direction {
      $$ = parser->ast()->createNodeSortElement($1, $2);
    }
  ;

sort_direction:
    /* empty */ {
      $$ = parser->ast()->createNodeValueBool(true);
    }
  | T_ASC {
      $$ = parser->ast()->createNodeValueBool(true);
    } 
  | T_DESC {
      $$ = parser->ast()->createNodeValueBool(false);
    }
  | simple_value {
      $$ = $1;
    }
  ;

limit_statement: 
    T_LIMIT simple_value {
      auto offset = parser->ast()->createNodeValueInt(0);
      auto node = parser->ast()->createNodeLimit(offset, $2);
      parser->ast()->addOperation(node);
    }
  | T_LIMIT simple_value T_COMMA simple_value {
      auto node = parser->ast()->createNodeLimit($2, $4);
      parser->ast()->addOperation(node);
    }
  ;

return_statement:
    T_RETURN distinct_expression {
      auto node = parser->ast()->createNodeReturn($2);
      parser->ast()->addOperation(node);
      parser->ast()->scopes()->endNested();
    }
  ;

in_or_into_collection:
    T_IN collection_name {
      $$ = $2;
    }
  | T_INTO collection_name {
       $$ = $2;
     }
   ;

remove_statement:
    T_REMOVE expression in_or_into_collection options {
      if (! parser->configureWriteQuery($3, $4)) {
        YYABORT;
      }
      auto node = parser->ast()->createNodeRemove($2, $3, $4);
      parser->ast()->addOperation(node);
    }
  ;

insert_statement:
    T_INSERT expression in_or_into_collection options {
      if (! parser->configureWriteQuery($3, $4)) {
        YYABORT;
      }
      auto node = parser->ast()->createNodeInsert($2, $3, $4);
      parser->ast()->addOperation(node);
    }
  ;

update_parameters:
    expression in_or_into_collection options {
      if (! parser->configureWriteQuery($2, $3)) {
        YYABORT;
      }

      AstNode* node = parser->ast()->createNodeUpdate(nullptr, $1, $2, $3);
      parser->ast()->addOperation(node);
    }
  | expression T_WITH expression in_or_into_collection options {
      if (! parser->configureWriteQuery($4, $5)) {
        YYABORT;
      }

      AstNode* node = parser->ast()->createNodeUpdate($1, $3, $4, $5);
      parser->ast()->addOperation(node);
    }
  ;

update_statement:
    T_UPDATE update_parameters {
    }
  ;

replace_parameters:
    expression in_or_into_collection options {
      if (! parser->configureWriteQuery($2, $3)) {
        YYABORT;
      }

      AstNode* node = parser->ast()->createNodeReplace(nullptr, $1, $2, $3);
      parser->ast()->addOperation(node);
    }
  | expression T_WITH expression in_or_into_collection options {
      if (! parser->configureWriteQuery($4, $5)) {
        YYABORT;
      }

      AstNode* node = parser->ast()->createNodeReplace($1, $3, $4, $5);
      parser->ast()->addOperation(node);
    }
  ;

replace_statement:
    T_REPLACE replace_parameters {
    }
  ;

update_or_replace:
    T_UPDATE {
      $$ = static_cast<int64_t>(NODE_TYPE_UPDATE);
    }
  | T_REPLACE {
      $$ = static_cast<int64_t>(NODE_TYPE_REPLACE);
    }
  ;

upsert_statement:
    T_UPSERT { 
      // reserve a variable named "$OLD", we might need it in the update expression
      // and in a later return thing
      parser->pushStack(parser->ast()->createNodeVariable(TRI_CHAR_LENGTH_PAIR(Variable::NAME_OLD), true));
    } expression T_INSERT expression update_or_replace expression in_or_into_collection options {
      if (! parser->configureWriteQuery($8, $9)) {
        YYABORT;
      }

      AstNode* variableNode = static_cast<AstNode*>(parser->popStack());
      
      auto scopes = parser->ast()->scopes();
      
      scopes->start(arangodb::aql::AQL_SCOPE_SUBQUERY);
      parser->ast()->startSubQuery();
      
      scopes->start(arangodb::aql::AQL_SCOPE_FOR);
      std::string const variableName = parser->ast()->variables()->nextName();
      auto forNode = parser->ast()->createNodeFor(variableName.c_str(), variableName.size(), $8, false);
      parser->ast()->addOperation(forNode);

      auto filterNode = parser->ast()->createNodeUpsertFilter(parser->ast()->createNodeReference(variableName), $3);
      parser->ast()->addOperation(filterNode);
      
      auto offsetValue = parser->ast()->createNodeValueInt(0);
      auto limitValue = parser->ast()->createNodeValueInt(1);
      auto limitNode = parser->ast()->createNodeLimit(offsetValue, limitValue);
      parser->ast()->addOperation(limitNode);
      
      auto refNode = parser->ast()->createNodeReference(variableName);
      auto returnNode = parser->ast()->createNodeReturn(refNode);
      parser->ast()->addOperation(returnNode);
      scopes->endNested();

      AstNode* subqueryNode = parser->ast()->endSubQuery();
      scopes->endCurrent();
      
      std::string const subqueryName = parser->ast()->variables()->nextName();
      auto subQuery = parser->ast()->createNodeLet(subqueryName.c_str(), subqueryName.size(), subqueryNode, false);
      parser->ast()->addOperation(subQuery);
      
      auto index = parser->ast()->createNodeValueInt(0);
      auto firstDoc = parser->ast()->createNodeLet(variableNode, parser->ast()->createNodeIndexedAccess(parser->ast()->createNodeReference(subqueryName), index));
      parser->ast()->addOperation(firstDoc);

      auto node = parser->ast()->createNodeUpsert(static_cast<AstNodeType>($6), parser->ast()->createNodeReference(TRI_CHAR_LENGTH_PAIR(Variable::NAME_OLD)), $5, $7, $8, $9);
      parser->ast()->addOperation(node);
    }
  ;

quantifier: 
    T_ALL {
      $$ = parser->ast()->createNodeQuantifier(Quantifier::ALL);
    }
  | T_ANY {
      $$ = parser->ast()->createNodeQuantifier(Quantifier::ANY);
    }
  | T_NONE {
      $$ = parser->ast()->createNodeQuantifier(Quantifier::NONE);
    }
  ;

distinct_expression:
    T_DISTINCT {
      auto const scopeType = parser->ast()->scopes()->type();

      if (scopeType == AQL_SCOPE_MAIN ||
          scopeType == AQL_SCOPE_SUBQUERY) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "cannot use DISTINCT modifier on top-level query element", yylloc.first_line, yylloc.first_column);
      }
    } expression {
      $$ = parser->ast()->createNodeDistinct($3);
    }
  | expression {
      $$ = $1;
    }
  ;

expression:
    operator_unary {
      $$ = $1;
    }
  | operator_binary {
      $$ = $1;
    }
  | operator_ternary {
      $$ = $1;
    }
  | value_literal {
      $$ = $1;
    }
  | reference {
      $$ = $1;
    }
  | expression T_RANGE expression {
      $$ = parser->ast()->createNodeRange($1, $3);
    }
  ;

function_name:
    T_STRING {
      $$ = $1;
    }
  | function_name T_SCOPE T_STRING {
      std::string temp($1.value, $1.length);
      temp.append("::");
      temp.append($3.value, $3.length);
      auto p = parser->query()->registerString(temp);

      if (p == nullptr) {
        ABORT_OOM
      }

      $$.value = p;
      $$.length = temp.size();
    }
  ;

function_call:
    function_name T_OPEN {
      parser->pushStack($1.value);

      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } optional_function_call_arguments T_CLOSE %prec FUNCCALL {
      auto list = static_cast<AstNode const*>(parser->popStack());
      $$ = parser->ast()->createNodeFunctionCall(static_cast<char const*>(parser->popStack()), list);
    } 
  | T_LIKE T_OPEN {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } optional_function_call_arguments T_CLOSE %prec FUNCCALL {
      auto list = static_cast<AstNode const*>(parser->popStack());
      $$ = parser->ast()->createNodeFunctionCall("LIKE", list);
    } 
  ;

operator_unary:
    T_PLUS expression %prec UPLUS {
      $$ = parser->ast()->createNodeUnaryOperator(NODE_TYPE_OPERATOR_UNARY_PLUS, $2);
    }
  | T_MINUS expression %prec UMINUS {
      $$ = parser->ast()->createNodeUnaryOperator(NODE_TYPE_OPERATOR_UNARY_MINUS, $2);
    }
  | T_NOT expression %prec T_NOT { 
      $$ = parser->ast()->createNodeUnaryOperator(NODE_TYPE_OPERATOR_UNARY_NOT, $2);
    }
  ;

operator_binary:
    expression T_OR expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_OR, $1, $3);
    }
  | expression T_AND expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_AND, $1, $3);
    }
  | expression T_PLUS expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_PLUS, $1, $3);
    }
  | expression T_MINUS expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_MINUS, $1, $3);
    }
  | expression T_TIMES expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_TIMES, $1, $3);
    }
  | expression T_DIV expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_DIV, $1, $3);
    }
  | expression T_MOD expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_MOD, $1, $3);
    }
  | expression T_EQ expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_EQ, $1, $3);
    }
  | expression T_NE expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_NE, $1, $3);
    }
  | expression T_LT expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_LT, $1, $3);
    }
  | expression T_GT expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_GT, $1, $3);
    } 
  | expression T_LE expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_LE, $1, $3);
    }
  | expression T_GE expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_GE, $1, $3);
    }
  | expression T_IN expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_IN, $1, $3);
    }
  | expression T_NIN expression {
      $$ = parser->ast()->createNodeBinaryOperator(NODE_TYPE_OPERATOR_BINARY_NIN, $1, $3);
    }
  | expression T_LIKE expression {
      AstNode* arguments = parser->ast()->createNodeArray(2);
      arguments->addMember($1);
      arguments->addMember($3);
      $$ = parser->ast()->createNodeFunctionCall("LIKE", arguments);
    }
  | expression T_REGEX_MATCH expression {
      AstNode* arguments = parser->ast()->createNodeArray(2);
      arguments->addMember($1);
      arguments->addMember($3);
      $$ = parser->ast()->createNodeFunctionCall("REGEX_TEST", arguments);
    }
  | expression T_REGEX_NON_MATCH expression {
      AstNode* arguments = parser->ast()->createNodeArray(2);
      arguments->addMember($1);
      arguments->addMember($3);
      AstNode* node = parser->ast()->createNodeFunctionCall("REGEX_TEST", arguments);
      $$ = parser->ast()->createNodeUnaryOperator(NODE_TYPE_OPERATOR_UNARY_NOT, node);
    }
  | expression quantifier T_EQ expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_EQ, $1, $4, $2);
    }
  | expression quantifier T_NE expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_NE, $1, $4, $2);
    }
  | expression quantifier T_LT expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_LT, $1, $4, $2);
    }
  | expression quantifier T_GT expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_GT, $1, $4, $2);
    } 
  | expression quantifier T_LE expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_LE, $1, $4, $2);
    }
  | expression quantifier T_GE expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_GE, $1, $4, $2);
    }
  | expression quantifier T_IN expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_IN, $1, $4, $2);
    }
  | expression quantifier T_NIN expression {
      $$ = parser->ast()->createNodeBinaryArrayOperator(NODE_TYPE_OPERATOR_BINARY_ARRAY_NIN, $1, $4, $2);
    }
  ;

operator_ternary:
    expression T_QUESTION expression T_COLON expression {
      $$ = parser->ast()->createNodeTernaryOperator($1, $3, $5);
    }
  ;

optional_function_call_arguments: 
    /* empty */ {
    }
  | function_arguments_list {
    }
  ;

expression_or_query:
    expression {
      $$ = $1;
    }
  | {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_SUBQUERY);
      parser->ast()->startSubQuery();
    } query {
      AstNode* node = parser->ast()->endSubQuery();
      parser->ast()->scopes()->endCurrent();

      std::string const variableName = parser->ast()->variables()->nextName();
      auto subQuery = parser->ast()->createNodeLet(variableName.c_str(), variableName.size(), node, false);
      parser->ast()->addOperation(subQuery);

      $$ = parser->ast()->createNodeReference(variableName);
    }
  ;

function_arguments_list:
    expression_or_query {
      parser->pushArrayElement($1);
    }
  | function_arguments_list T_COMMA expression_or_query {
      parser->pushArrayElement($3);
    }
  ;

compound_value:
    array {
      $$ = $1;
    }
  | object {
      $$ = $1;
    }
  ;

array: 
    T_ARRAY_OPEN {
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
    } optional_array_elements T_ARRAY_CLOSE {
      $$ = static_cast<AstNode*>(parser->popStack());
    }
  ;

optional_array_elements:
    /* empty */ {
    }
  | array_elements_list {
    }
  ;

array_elements_list:
    expression {
      parser->pushArrayElement($1);
    }
  | array_elements_list T_COMMA expression {
      parser->pushArrayElement($3);
    }
  ;

options:
    /* empty */ {
      $$ = nullptr;
    }
  | T_STRING object {
      if ($2 == nullptr) {
        ABORT_OOM
      }

      if (! TRI_CaseEqualString($1.value, "OPTIONS")) {
        parser->registerParseError(TRI_ERROR_QUERY_PARSE, "unexpected qualifier '%s', expecting 'OPTIONS'", $1.value, yylloc.first_line, yylloc.first_column);
      }

      $$ = $2;
    }
  ;

object:
    T_OBJECT_OPEN {
      auto node = parser->ast()->createNodeObject();
      parser->pushStack(node);
    } optional_object_elements T_OBJECT_CLOSE {
      $$ = static_cast<AstNode*>(parser->popStack());
    }
  ;

optional_object_elements:
    /* empty */ {
    }
  | object_elements_list {
    }
  ;

object_elements_list:
    object_element {
    }
  | object_elements_list T_COMMA object_element {
    }
  ;

object_element: 
    T_STRING {
      // attribute-name-only (comparable to JS enhanced object literals, e.g. { foo, bar })
      auto ast = parser->ast();
      auto variable = ast->scopes()->getVariable($1.value, $1.length, true);
      
      if (variable == nullptr) {
        // variable does not exist
        parser->registerParseError(TRI_ERROR_QUERY_VARIABLE_NAME_UNKNOWN, "use of unknown variable '%s' in object literal", $1.value, yylloc.first_line, yylloc.first_column);
      }

      // create a reference to the variable
      auto node = ast->createNodeReference(variable);
      parser->pushObjectElement($1.value, $1.length, node);
    }
  | object_element_name T_COLON expression {
      // attribute-name : attribute-value
      parser->pushObjectElement($1.value, $1.length, $3);
    }
  | T_PARAMETER T_COLON expression {
      // bind-parameter : attribute-value
      if ($1.length < 1 || $1.value[0] == '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), $1.value, yylloc.first_line, yylloc.first_column);
      }

      auto param = parser->ast()->createNodeParameter($1.value, $1.length);
      parser->pushObjectElement(param, $3);
    }
  | T_ARRAY_OPEN expression T_ARRAY_CLOSE T_COLON expression {
      // [ attribute-name-expression ] : attribute-value
      parser->pushObjectElement($2, $5);
    }
  ;

array_filter_operator:
    T_TIMES {
      $$ = 1;
    }
  | array_filter_operator T_TIMES {
      $$ = $1 + 1;
    } 
  ;

optional_array_filter:
    /* empty */ {
      $$ = nullptr;
    }
  | T_FILTER expression {
      $$ = $2;
    }
  ;

optional_array_limit:
    /* empty */ {
      $$ = nullptr;
    }
  | T_LIMIT expression {
      $$ = parser->ast()->createNodeArrayLimit(nullptr, $2);
    }
  | T_LIMIT expression T_COMMA expression {
      $$ = parser->ast()->createNodeArrayLimit($2, $4);
    }
  ;

optional_array_return:
    /* empty */ {
      $$ = nullptr;
    }
  | T_RETURN expression {
      $$ = $2;
    }
  ;

graph_collection:
    T_STRING {
      $$ = parser->ast()->createNodeValueString($1.value, $1.length);
    }
  | bind_parameter {
      char const* p = $1->getStringValue();
      size_t const len = $1->getStringLength();
      if (len < 1 || *p != '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), p, yylloc.first_line, yylloc.first_column);
      }
      $$ = $1;
    }
  | graph_direction T_STRING {
      auto tmp = parser->ast()->createNodeValueString($2.value, $2.length);
      $$ = parser->ast()->createNodeCollectionDirection($1, tmp);
    }
  | graph_direction bind_parameter {
      char const* p = $2->getStringValue();
      size_t const len = $2->getStringLength();
      if (len < 1 || *p != '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), p, yylloc.first_line, yylloc.first_column);
      }
      $$ = parser->ast()->createNodeCollectionDirection($1, $2);
    }
  ;

graph_collection_list:
     graph_collection {
       auto node = static_cast<AstNode*>(parser->peekStack());
       node->addMember($1);
     }
   | graph_collection_list T_COMMA graph_collection {
       auto node = static_cast<AstNode*>(parser->peekStack());
       node->addMember($3);
     }
   ;

graph_subject:
    graph_collection {
      auto node = parser->ast()->createNodeArray();
      node->addMember($1);
      $$ = parser->ast()->createNodeCollectionList(node);
    }
  | graph_collection T_COMMA { 
      auto node = parser->ast()->createNodeArray();
      parser->pushStack(node);
      node->addMember($1);
    } graph_collection_list {
      auto node = static_cast<AstNode*>(parser->popStack());
      $$ = parser->ast()->createNodeCollectionList(node);
    }
  | T_GRAPH bind_parameter {
      // graph name
      char const* p = $2->getStringValue();
      size_t const len = $2->getStringLength();
      if (len < 1 || *p == '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), p, yylloc.first_line, yylloc.first_column);
      }
      $$ = $2;
    }
  | T_GRAPH T_QUOTED_STRING {
      // graph name
      $$ = parser->ast()->createNodeValueString($2.value, $2.length);
    }
  ;

graph_direction:
    // Returns the edge direction number.
    // Identical order as TRI_edge_direction_e
    T_OUTBOUND {
      $$ = 2;
    }
  | T_INBOUND {
      $$ = 1;
    }
  | T_ANY {
      $$ = 0; 
    }
  ;

graph_direction_steps:
    graph_direction {
      $$ = parser->ast()->createNodeDirection($1, 1);
    }
  | expression graph_direction %prec T_OUTBOUND {
      $$ = parser->ast()->createNodeDirection($2, $1);
    }
  ;

reference:
    T_STRING {
      // variable or collection
      auto ast = parser->ast();
      AstNode* node = nullptr;

      auto variable = ast->scopes()->getVariable($1.value, $1.length, true);
      
      if (variable == nullptr) {
        // variable does not exist
        // now try special variables
        if (ast->scopes()->canUseCurrentVariable() && strcmp($1.value, "CURRENT") == 0) {
          variable = ast->scopes()->getCurrentVariable();
        }
        else if (strcmp($1.value, Variable::NAME_CURRENT) == 0) {
          variable = ast->scopes()->getCurrentVariable();
        }
      }
        
      if (variable != nullptr) {
        // variable alias exists, now use it
        node = ast->createNodeReference(variable);
      }

      if (node == nullptr) {
        // variable not found. so it must have been a collection
        node = ast->createNodeCollection($1.value, TRI_TRANSACTION_READ);
      }

      TRI_ASSERT(node != nullptr);

      $$ = node;
    }
  | compound_value {
      $$ = $1;
    }
  | bind_parameter {
      $$ = $1;
    }
  | function_call {
      $$ = $1;
      
      if ($$ == nullptr) {
        ABORT_OOM
      }
    }
  | T_OPEN expression T_CLOSE {
      if ($2->type == NODE_TYPE_EXPANSION) {
        // create a dummy passthru node that reduces and evaluates the expansion first
        // and the expansion on top of the stack won't be chained with any other expansions
        $$ = parser->ast()->createNodePassthru($2);
      }
      else {
        $$ = $2;
      }
    }
  | T_OPEN {
      parser->ast()->scopes()->start(arangodb::aql::AQL_SCOPE_SUBQUERY);
      parser->ast()->startSubQuery();
    } query T_CLOSE {
      AstNode* node = parser->ast()->endSubQuery();
      parser->ast()->scopes()->endCurrent();

      std::string const variableName = parser->ast()->variables()->nextName();
      auto subQuery = parser->ast()->createNodeLet(variableName.c_str(), variableName.size(), node, false);
      parser->ast()->addOperation(subQuery);

      $$ = parser->ast()->createNodeReference(variableName);
    } 
  | reference '.' T_STRING %prec REFERENCE {
      // named variable access, e.g. variable.reference
      if ($1->type == NODE_TYPE_EXPANSION) {
        // if left operand is an expansion already...
        // dive into the expansion's right-hand child nodes for further expansion and
        // patch the bottom-most one
        auto current = const_cast<AstNode*>(parser->ast()->findExpansionSubNode($1));
        TRI_ASSERT(current->type == NODE_TYPE_EXPANSION);
        current->changeMember(1, parser->ast()->createNodeAttributeAccess(current->getMember(1), $3.value, $3.length));
        $$ = $1;
      }
      else {
        $$ = parser->ast()->createNodeAttributeAccess($1, $3.value, $3.length);
      }
    }
  | reference '.' bind_parameter %prec REFERENCE {
      // named variable access, e.g. variable.@reference
      if ($1->type == NODE_TYPE_EXPANSION) {
        // if left operand is an expansion already...
        // patch the existing expansion
        auto current = const_cast<AstNode*>(parser->ast()->findExpansionSubNode($1));
        TRI_ASSERT(current->type == NODE_TYPE_EXPANSION);
        current->changeMember(1, parser->ast()->createNodeBoundAttributeAccess(current->getMember(1), $3));
        $$ = $1;
      }
      else {
        $$ = parser->ast()->createNodeBoundAttributeAccess($1, $3);
      }
    }
  | reference T_ARRAY_OPEN expression T_ARRAY_CLOSE %prec INDEXED {
      // indexed variable access, e.g. variable[index]
      if ($1->type == NODE_TYPE_EXPANSION) {
        // if left operand is an expansion already...
        // patch the existing expansion
        auto current = const_cast<AstNode*>(parser->ast()->findExpansionSubNode($1));
        TRI_ASSERT(current->type == NODE_TYPE_EXPANSION);
        current->changeMember(1, parser->ast()->createNodeIndexedAccess(current->getMember(1), $3));
        $$ = $1;
      }
      else {
        $$ = parser->ast()->createNodeIndexedAccess($1, $3);
      }
    }
  | reference T_ARRAY_OPEN array_filter_operator {
      // variable expansion, e.g. variable[*], with optional FILTER, LIMIT and RETURN clauses
      if ($3 > 1 && $1->type == NODE_TYPE_EXPANSION) {
        // create a dummy passthru node that reduces and evaluates the expansion first
        // and the expansion on top of the stack won't be chained with any other expansions
        $1 = parser->ast()->createNodePassthru($1);
      }

      // create a temporary iterator variable
      std::string const nextName = parser->ast()->variables()->nextName() + "_";

      if ($1->type == NODE_TYPE_EXPANSION) {
        auto iterator = parser->ast()->createNodeIterator(nextName.c_str(), nextName.size(), $1->getMember(1));
        parser->pushStack(iterator);
      }
      else {
        auto iterator = parser->ast()->createNodeIterator(nextName.c_str(), nextName.size(), $1);
        parser->pushStack(iterator);
      }

      auto scopes = parser->ast()->scopes();
      scopes->stackCurrentVariable(scopes->getVariable(nextName));
    } optional_array_filter optional_array_limit optional_array_return T_ARRAY_CLOSE %prec EXPANSION {
      auto scopes = parser->ast()->scopes();
      scopes->unstackCurrentVariable();

      auto iterator = static_cast<AstNode const*>(parser->popStack());
      auto variableNode = iterator->getMember(0);
      TRI_ASSERT(variableNode->type == NODE_TYPE_VARIABLE);
      auto variable = static_cast<Variable const*>(variableNode->getData());

      if ($1->type == NODE_TYPE_EXPANSION) {
        auto expand = parser->ast()->createNodeExpansion($3, iterator, parser->ast()->createNodeReference(variable->name), $5, $6, $7);
        $1->changeMember(1, expand);
        $$ = $1;
      }
      else {
        $$ = parser->ast()->createNodeExpansion($3, iterator, parser->ast()->createNodeReference(variable->name), $5, $6, $7);
      }
    }
  ;

simple_value:
    value_literal {
      $$ = $1;
    }
  | bind_parameter {
      $$ = $1;
    }
  ;

numeric_value:
    T_INTEGER {
      if ($1 == nullptr) {
        ABORT_OOM
      }
      
      $$ = $1;
    }
  | T_DOUBLE {
      if ($1 == nullptr) {
        ABORT_OOM
      }

      $$ = $1;
    }
  ;
  
value_literal: 
    T_QUOTED_STRING {
      $$ = parser->ast()->createNodeValueString($1.value, $1.length);
    }
  | numeric_value {
      $$ = $1;
    }
  | T_NULL {
      $$ = parser->ast()->createNodeValueNull();
    }
  | T_TRUE {
      $$ = parser->ast()->createNodeValueBool(true);
    }
  | T_FALSE {
      $$ = parser->ast()->createNodeValueBool(false);
    }
  ;

collection_name:
    T_STRING {
      $$ = parser->ast()->createNodeCollection($1.value, TRI_TRANSACTION_WRITE);
    }
  | T_QUOTED_STRING {
      $$ = parser->ast()->createNodeCollection($1.value, TRI_TRANSACTION_WRITE);
    }
  | T_PARAMETER {
      if ($1.length < 2 || $1.value[0] != '@') {
        parser->registerParseError(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE, TRI_errno_string(TRI_ERROR_QUERY_BIND_PARAMETER_TYPE), $1.value, yylloc.first_line, yylloc.first_column);
      }

      $$ = parser->ast()->createNodeParameter($1.value, $1.length);
    }
  ;

bind_parameter:
    T_PARAMETER {
      $$ = parser->ast()->createNodeParameter($1.value, $1.length);
    }
  ;

object_element_name:
    T_STRING {
      $$ = $1;
    }
  | T_QUOTED_STRING {
      $$ = $1;
    }

variable_name:
    T_STRING {
      $$ = $1;
    }
  ;


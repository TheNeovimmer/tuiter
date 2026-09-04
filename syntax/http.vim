" tuiter .http syntax highlighting
" Vim syntax file
" Language: HTTP Request (tuiter / REST Client)

if exists("b:current_syntax")
  finish
endif

" Section headers: ### My Request Name
syn match httpSection /^###\s.*$/ contains=httpSectionMarker
syn match httpSectionMarker /^###/ contained

" HTTP methods
syn match httpMethod /^\s*\zs\(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\)\ze\s/ contained

" Request line: METHOD URL
syn match httpRequestLine /^\s*\(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\)\s\+\S+/ contains=httpMethod,httpUrl
syn match httpUrl /\S+/ contained containedin=httpRequestLine

" URLs with {{var}} interpolation
syn match httpUrlVar /{{[^}]*}}/ contained containedin=httpUrl

" Directives: # @name, # @base, # @auth, # @test, # @before, # @after, etc.
syn match httpDirective /^#\s*@[\w-]*/ contains=httpDirectiveAt
syn match httpDirectiveAt /@/ contained

" Directive values (everything after the directive)
syn match httpDirectiveValue /^#\s*@[\w-]*\s\+\zs.*$/ contained

" Lua script blocks (# @before / # @after)
syn region httpScript start=/^#\s*@\%(before\|after\|lua_pre\|lua_post\)\s/ end=/^#/me=e-1 contains=httpDirective,httpScriptCode keepend
syn match httpScriptCode /.\+/ contained

" Variable assignments: @var = value
syn match httpVarAssign /^@\w\+\s*=\s*.*$/ contains=httpVarName,httpVarEq,httpVarValue
syn match httpVarName /@\w\+/ contained
syn match httpVarEq /=/ contained
syn match httpVarValue /=\s*\zs.*$/ contained

" Headers: Key: Value (before blank line or body)
syn match httpHeaderKey /^\s*\zs[\w-]\+\ze\s*:/ contained
syn match httpHeaderValue /:\s*\zs.*$/ contained
syn match httpHeaderLine /^[\w-]\+\s*:.*$/ contains=httpHeaderKey,httpHeaderValue

" {{variable}} interpolation in headers and URLs
syn match httpVariable /{{[^}]*}}/

" Separator line between sections
syn match httpSeparator /^###\s*$/ 

" Comments (lines starting with # but not directives)
syn match httpComment /^#\s\+.*$/ contains=httpCommentHash
syn match httpCommentHash /^#\s\+/ contained

" JSON body highlighting
syn region httpBody start=/^\s*[{[]/ end=/^\s*[}\]]/ contains=jsonBraces,jsonString,jsonNumber,jsonKeyword,jsonBoolean,jsonNull fold transparent
syn match jsonBraces /[{}]/
syn match jsonBraces /[[\]]/
syn region jsonString start=/"/ end=/"/ contains=httpVariable
syn match jsonNumber /-\?\d\+\(\.\d\+\)\?\([eE][-+]\?\d\+\)\?/
syn match jsonKeyword /"\ze[^"]*":/ 
syn match jsonBoolean /\<\(true\|false\)\>/
syn match jsonNull /\<null\>/

" Request body separator (blank line between headers and body)
syn match httpBodyStart /^$/ 

" Status codes in comments or responses
syn match httpStatusCode /\<[1-5][0-9][0-9]\>/

" Highlight links
hi def link httpSection Title
hi def link httpSectionMarker Delimiter
hi def link httpMethod Function
hi def link httpRequestLine Statement
hi def link httpUrl String
hi def link httpUrlVar Special
hi def link httpVariable Special
hi def link httpDirective PreProc
hi def link httpDirectiveAt Delimiter
hi def link httpDirectiveValue String
hi def link httpVarAssign Identifier
hi def link httpVarName Identifier
hi def link httpVarEq Operator
hi def link httpVarValue String
hi def link httpHeaderKey Type
hi def link httpHeaderValue String
hi def link httpHeaderLine Identifier
hi def link httpComment Comment
hi def link httpCommentHash Comment
hi def link httpSeparator Delimiter
hi def link httpBodyStart Comment
hi def link httpScript PreProc
hi def link httpScriptCode String
hi def link jsonBraces Delimiter
hi def link jsonString String
hi def link jsonNumber Number
hi def link jsonKeyword Label
hi def link jsonBoolean Boolean
hi def link jsonNull Constant
hi def link httpStatusCode Number

let b:current_syntax = "http"

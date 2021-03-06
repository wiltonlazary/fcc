module ast.platform;

import ast.base, parseBase, ast.fun, ast.namespace, ast.pointer, ast.stringparse, ast.scopes;

import tools.base: endsWith;

PassthroughWeakNoOp parseGlobalBody(ref string src, ParseCb rest, bool stmt) {
  Object obj;
  IsMangled[] mangles;
  auto ns = namespace(), mod = fastcast!(Module) (current_module());
  if (!src.many(
      !!rest(src, stmt?"tree.stmt":"tree.toplevel"[], &obj),
      {
        if (auto im = fastcast!(IsMangled)(obj)) mangles ~= im;
        if (stmt) {
          if (auto st = fastcast!(Statement) (obj)) {
            if (!fastcast!(NoOp)(st)) {
              auto sc = fastcast!(Scope) (ns);
              if (!sc) fail(qformat("ns was a ", fastcast!(Object)(namespace()).classinfo.name, " ", ns, ", not a Scope that we can add ", st, " to"));
              sc.addStatement(st);
            }
          }
        } else {
          if (auto n = fastcast!(Named) (obj))
            if (!addsSelf(obj))
              ns.add(n);
          if (auto tr = fastcast!(Tree) (obj)) mod.addEntry(tr);
        }
      }
    ))
    src.failparse("Failed to parse platform body. "[]);
  src.eatComments();
  if (src.mystripl().length) {
    src.failparse("Unknown statement. "[]);
  }
  return fastalloc!(PassthroughWeakNoOp)(mangles);
}

import ast.modules;
Object gotPlatform(bool Stmt)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string platname;
  bool neg, wildfront, wildback;
  if (!t2.accept("("[])) return null;
  if (t2.accept("!"[])) neg = true;
  if (t2.accept("*"[])) wildfront = true;
  {
    bool gotNeg;
    if (t2.accept("-"[])) gotNeg = true;
    if (!t2.gotIdentifier(platname))
      t2.failparse("Invalid platform identifier"[]);
    if (gotNeg) platname = "-"~platname;
  }
  if (t2.accept("*"[])) wildback = true;
  if (!t2.accept(")"[]))
    t2.failparse("expected closing paren"[]);
  t2.noMoreHeredoc();
  auto src = t2.coarseLexScope(true, false);
  auto ns = namespace(), mod = fastcast!(Module) (current_module());
  bool match;
  if (platname == "x86") {
    match = !platform_prefix || platform_prefix.find("mingw") != -1;
  } else if (platname == "posix") {
    match = !platform_prefix || platform_prefix.startsWith("arm");
  } else {
    match = platname~"-" == platform_prefix || platname == "default" && !platform_prefix;
  }
  if (wildfront && wildback) match |=   platform_prefix.find(platname) != -1;
  if (wildfront &&!wildback) match |= !!platform_prefix.endsWith(platname~"-"[]);
  if(!wildfront && wildback) match |= !!platform_prefix.startsWith(platname);
  if (neg) match = !match;
  if (match) {
    src.parseGlobalBody (rest, Stmt);
  }
  text = t2;
  return Single!(NoOp);
}
mixin DefaultParser!(gotPlatform!(false), "tree.toplevel.a_platform", null, "platform"); // sort first because is cheap to exclude
mixin DefaultParser!(gotPlatform!(true), "tree.stmt.platform", "311", "platform");

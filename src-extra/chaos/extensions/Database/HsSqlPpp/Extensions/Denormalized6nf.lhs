
silly name, idea is to match some sort of oo inheritance approach to
create a set of 6nf relvars, and then implement using a single table
with nulls, adding appropriate constraints to restrict which
combinations of nulls are possible, and add views which return subsets
with no nulls in

example idea:

this is the basic table we want to produce

~~~~{.sql}
create table piece_prototypes (
  ptype text primary key,
  flying boolean null,
  speed int null,
  agility int null,
  undead boolean null,
  ridable boolean null,
  ranged_weapon_type text,
  range int null,
  ranged_attack_strength int null,
  attack_strength int null,
  physical_defense int null,
  magic_defense int null
);
~~~~

these fields are group as follows

~~~~
proto
  ptype
creature
  flying
  speed
  agility
attacking
  attack_strength
attackable
  physical_defense
  magic_defense
ranged
  ranged_weapon_type
  range
monster
  undead
  ridable
~~~~

so if a row has a non null in one member of a group, they all must be
non null (e.g. flying,speed, agility must all be null or all non null)

we also have group dependencies,e.g. if a row is monster,(i.e.  undead
and ridable are non null), it also has to be a creature, attacking and
attackable (so all their fields have to be non null)

want to describe the table in these terms and have:

* the full table created
* check constraints on combinations of null with nice error messages
* views which show restrict/projections without the nulls

see the examples file for more details

question: how can a client read a whole table like this and not have
to deal with nulls/ maybe types?

> {-# LANGUAGE QuasiQuotes, ScopedTypeVariables #-}
> module Database.HsSqlPpp.Extensions.Denormalized6nf
>     (denormalized6nf) where
>
> import Data.Generics
> import Data.Generics.Uniplate.Data
> import Data.List
> import Data.Maybe
>
> import Database.HsSqlPpp.Extensions.DenormSyntax
> import Database.HsSqlPpp.Ast
> import Database.HsSqlPpp.Quote
> import Database.HsSqlPpp.Annotation
> import Database.HsSqlPpp.Extensions.AstUtils
>
> denormalized6nf :: Data a => a -> a
> denormalized6nf =
>   transformBi $ \x ->
>       case x of
>         st@[sqlStmt| select create6nf($e(stuff)); |] : tl
>             -> let (f,l,c) = fromMaybe ("",1,1) $ anSrc $ getAnnotation stuff
>                    (StringLit _ s) = stuff
>                in replaceSourcePos st (createStatements f l c s) ++ tl
>         x1 -> x1
>   where
>       createStatements f l c s =
>           case parseD6nf f l c s of
>             Left e -> error e
>             Right t -> let (cons, vs) = (makeViews t)
>                        in makeTable cons t : vs
>
> makeTable :: [Constraint] -> [D6nfStatement] -> Statement
> makeTable cs dss =
>     let (s2,f2) = head [(s1,f1) | DTable s1 [] f1 <- universeBi dss]
>         f3 = [f1 | DTable s3 _ f1 <- universeBi dss, s3 /= s2]
>     in CreateTable ea (Name ea [Nmc s2]) (map notNullify f2 ++ map nullify (concat f3)) cs Nothing
>
>
> notNullify :: AttributeDef -> AttributeDef
> notNullify ad@(AttributeDef a n t d cs) =
>   if hasPk
>   then ad
>   else AttributeDef a n t d (NotNullConstraint ea "" : cs)
>   where
>     hasPk = isJust $ flip find cs
>                        $ \l -> case l of
>                                       RowPrimaryKeyConstraint _ _ -> True
>                                       _ -> False
>
> nullify :: AttributeDef -> AttributeDef
> nullify (AttributeDef a n t d cs) =
>     AttributeDef a n t d (NullConstraint ea "" : cs)

> attributeName :: AttributeDef -> String
> attributeName (AttributeDef _ n _ _ _) = ncStr n

> makeViews :: [D6nfStatement] -> ([Constraint], [Statement])
> makeViews dss =
>     let (bottomTableName,f2) = head [(s1,f1) | DTable s1 [] f1 <- universeBi dss]
>         bottomTableNamex = Name ea [Nmc bottomTableName]
>         subt = [(tn,sts,f1) | DTable tn sts f1 <- universeBi dss, tn /= bottomTableName]
>         baseName = bottomTableName ++ "_base"
>         baseNamex = Name ea [Nmc baseName]
>         baseAttrIds = map idFromAttr f2
>         fixSelectList attrs st =
>           flip transformBi st $ \x ->
>             case x of
>               SelectList _ _ -> SelectList ea (map (SelExp ea) attrs)
>               -- x1 -> x1
>         makeConstraint :: (String,[(String,[ScalarExpr])]) -> Maybe Constraint
>         makeConstraint (tn, flds) =
>           let newFields = case reverse flds of
>                               (_, f): _ -> f
>                               _ -> []
>               noNewFields = null newFields
>               allFields = nub $ concatMap snd flds
>               -- want to make sure if any of the new fields are not null
>               -- than all the fields from parents as well must be not null
>               nots = andTogether $ map makeNotNull allFields
>               -- only want to ensure the new fields have to all be null
>               -- don't care about parent fields
>               nulls = andTogether $ map makeNull newFields
>           in
>              if noNewFields || null allFields || null (tail allFields)
>              then Nothing
>              else Just $ CheckConstraint ea (tn ++ "_fields")
>                           [sqlExpr| ($e(nulls)) or ($e(nots)) |]
>         makeView :: (String,[(String,[ScalarExpr])]) -> Statement
>         makeView (tn, flds) =
>           let allFields = nub $ concatMap snd flds
>               allFirstFields = nub $ mapMaybe ((\f -> case f of
>                                                              fh : _ -> Just fh
>                                                              _ -> Nothing) . snd) flds
>               expr = -- constraints mean we only need to check one field
>                      andTogether $ map makeNotNull allFirstFields
>                      --makeNotNull $ head allFields
>               tnx = Name ea [Nmc tn]
>           in fixSelectList (baseAttrIds ++ allFields)
>                [sqlStmt| create view $n(tnx) as
>                           select selectList from $n(bottomTableNamex)
>                             where $e(expr); |]
>     in (mapMaybe makeConstraint (getExtraFields subt)
>        ,fixSelectList baseAttrIds [sqlStmt| create view $n(baseNamex) as
>                                  select selectList from $n(bottomTableNamex);|] :
>         map makeView (getExtraFields subt))
>     where
>       idFromAttr = Identifier ea . Name ea . (:[]) . Nmc . attributeName
>       getExtraFields :: [(String,[String],[AttributeDef])] -> [(String,[(String,[ScalarExpr])])] -- table name, sourcetable,fieldlist
>       getExtraFields tinfo = let t1 = map gef tinfo
>                              in map (\a@((tn,_):_) -> (tn, reverse a)) t1 --first reverse here
>         where
>           gef :: (String,[String],[AttributeDef]) -> [(String,[ScalarExpr])]
>           gef (tn,subtns,attrs) =
>             let subtnlist :: [(String,[String],[AttributeDef])]
>                 subtnlist = mapMaybe lookupst subtns
>             in (tn, map idFromAttr attrs) : concatMap gef (reverse subtnlist) -- second reverse here
>           lookupst :: String -> Maybe (String,[String],[AttributeDef])
>           lookupst st = find (\(tn,_,_) -> tn == st) tinfo


the two reverses seem to be what's needed to get the field lists for
each view in the order a) they appear in the file, and b) base classes
first.

>
> makeNotNull :: ScalarExpr -> ScalarExpr
> makeNotNull x = [sqlExpr| $e(x) is not null |]
>
> makeNull :: ScalarExpr -> ScalarExpr
> makeNull x = [sqlExpr| $e(x) is null |]

> andTogether :: [ScalarExpr] -> ScalarExpr
> andTogether = let t = [sqlExpr| True |]
>               in foldr (\a b ->
>                          if b == t
>                          then a
>                          else [sqlExpr| $e(a) and $e(b) |]) t

> ea :: Annotation
> ea = emptyAnnotation

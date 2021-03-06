GOTO MAIN

REM $INCLUDE: 'types.in.bas'
REM $INCLUDE: 'readline.in.bas'
REM $INCLUDE: 'reader.in.bas'
REM $INCLUDE: 'printer.in.bas'
REM $INCLUDE: 'env.in.bas'
REM $INCLUDE: 'core.in.bas'

REM $INCLUDE: 'debug.in.bas'

REM READ(A$) -> R
MAL_READ:
  GOSUB READ_STR
  RETURN

REM QUASIQUOTE(A) -> R
SUB QUASIQUOTE
  REM pair?
  IF (Z%(A,0)AND 31)<6 OR (Z%(A,0)AND 31)>7 THEN GOTO QQ_QUOTE
  IF (Z%(A,1)=0) THEN GOTO QQ_QUOTE
  GOTO QQ_UNQUOTE

  QQ_QUOTE:
    REM ['quote, ast]
    B$="quote":T=5:GOSUB STRING
    B=R:A=A:GOSUB LIST2
    AY=B:GOSUB RELEASE

    GOTO QQ_DONE

  QQ_UNQUOTE:
    R=A:GOSUB VAL_R
    IF (Z%(R,0)AND 31)<>5 THEN GOTO QQ_SPLICE_UNQUOTE
    IF S$(Z%(R,1))<>"unquote" THEN GOTO QQ_SPLICE_UNQUOTE
      REM [ast[1]]
      R=Z%(A,1):GOSUB VAL_R
      Z%(R,0)=Z%(R,0)+32

      GOTO QQ_DONE

  QQ_SPLICE_UNQUOTE:
    GOSUB PUSH_A
    REM rest of cases call quasiquote on ast[1..]
    A=Z%(A,1):CALL QUASIQUOTE
    W=R
    GOSUB POP_A

    REM set A to ast[0] for last two cases
    GOSUB VAL_A

    REM pair?
    IF (Z%(A,0)AND 31)<6 OR (Z%(A,0)AND 31)>7 THEN GOTO QQ_DEFAULT
    IF (Z%(A,1)=0) THEN GOTO QQ_DEFAULT

    B=A:GOSUB VAL_B
    IF (Z%(B,0)AND 31)<>5 THEN GOTO QQ_DEFAULT
    IF S$(Z%(B,1))<>"splice-unquote" THEN QQ_DEFAULT
      REM ['concat, ast[0][1], quasiquote(ast[1..])]

      B=Z%(A,1):GOSUB VAL_B
      B$="concat":T=5:GOSUB STRING:C=R
      A=W:GOSUB LIST3
      REM release inner quasiquoted since outer list takes ownership
      AY=A:GOSUB RELEASE
      AY=C:GOSUB RELEASE
      GOTO QQ_DONE

  QQ_DEFAULT:
    REM ['cons, quasiquote(ast[0]), quasiquote(ast[1..])]

    Q=W:GOSUB PUSH_Q
    REM A set above to ast[0]
    CALL QUASIQUOTE
    B=R
    GOSUB POP_Q:W=Q

    B$="cons":T=5:GOSUB STRING:C=R
    A=W:GOSUB LIST3
    REM release inner quasiquoted since outer list takes ownership
    AY=A:GOSUB RELEASE
    AY=B:GOSUB RELEASE
    AY=C:GOSUB RELEASE
  QQ_DONE:
END SUB


REM EVAL_AST(A, E) -> R
SUB EVAL_AST
  REM push A and E on the stack
  Q=E:GOSUB PUSH_Q
  GOSUB PUSH_A

  IF ER<>-2 THEN GOTO EVAL_AST_RETURN

  T=Z%(A,0)AND 31
  IF T=5 THEN GOTO EVAL_AST_SYMBOL
  IF T>=6 AND T<=8 THEN GOTO EVAL_AST_SEQ

  REM scalar: deref to actual value and inc ref cnt
  R=A
  Z%(R,0)=Z%(R,0)+32
  GOTO EVAL_AST_RETURN

  EVAL_AST_SYMBOL:
    K=A:GOTO ENV_GET
    ENV_GET_RETURN:
    GOTO EVAL_AST_RETURN

  EVAL_AST_SEQ:
    REM setup the stack for the loop
    GOSUB MAP_LOOP_START

    EVAL_AST_SEQ_LOOP:
      REM check if we are done evaluating the source sequence
      IF Z%(A,1)=0 THEN GOTO EVAL_AST_SEQ_LOOP_DONE

      REM if we are returning to DO, then skip last element
      REM The EVAL_DO call to EVAL_AST must be call #2 for EVAL_AST to
      REM return early and for TCO to work
      Q=5:GOSUB PEEK_Q_Q
      IF Q=2 AND Z%(Z%(A,1),1)=0 THEN GOTO EVAL_AST_SEQ_LOOP_DONE

      REM call EVAL for each entry
      GOSUB PUSH_A
      IF T<>8 THEN GOSUB VAL_A
      IF T=8 THEN A=Z%(A+1,1)
      Q=T:GOSUB PUSH_Q: REM push/save type
      CALL EVAL
      GOSUB POP_Q:T=Q: REM pop/restore type
      GOSUB POP_A

      REM if error, release the unattached element
      REM TODO: is R=0 correct?
      IF ER<>-2 THEN AY=R:GOSUB RELEASE:R=0:GOTO EVAL_AST_SEQ_LOOP_DONE

      REM for hash-maps, copy the key (inc ref since we are going to
      REM release it below)
      IF T=8 THEN M=Z%(A+1,0):Z%(M,0)=Z%(M,0)+32

      REM value evaluated above
      N=R

      REM update the return sequence structure
      REM release N (and M if T=8) since seq takes full ownership
      C=1:GOSUB MAP_LOOP_UPDATE

      REM process the next sequence entry from source list
      A=Z%(A,1)

      GOTO EVAL_AST_SEQ_LOOP
    EVAL_AST_SEQ_LOOP_DONE:
      REM cleanup stack and get return value
      GOSUB MAP_LOOP_DONE
      GOTO EVAL_AST_RETURN

  EVAL_AST_RETURN:
    REM pop A and E off the stack
    GOSUB POP_A
    GOSUB POP_Q:E=Q
END SUB

REM EVAL(A, E) -> R
SUB EVAL
  LV=LV+1: REM track basic return stack level

  REM push A and E on the stack
  Q=E:GOSUB PUSH_Q
  GOSUB PUSH_A

  REM PRINT "EVAL A:"+STR$(A)+",X:"+STR$(X)+",LV:"+STR$(LV)+",FRE:"+STR$(FRE(0))

  EVAL_TCO_RECUR:

  IF ER<>-2 THEN GOTO EVAL_RETURN

  REM AZ=A:B=1:GOSUB PR_STR
  REM PRINT "EVAL: "+R$+" [A:"+STR$(A)+", LV:"+STR$(LV)+"]"

  GOSUB LIST_Q
  IF R THEN GOTO APPLY_LIST
  REM ELSE
    CALL EVAL_AST
    GOTO EVAL_RETURN

  APPLY_LIST:
    GOSUB EMPTY_Q
    IF R THEN R=A:Z%(R,0)=Z%(R,0)+32:GOTO EVAL_RETURN

    A0=Z%(A+1,1)

    REM get symbol in A$
    IF (Z%(A0,0)AND 31)<>5 THEN A$=""
    IF (Z%(A0,0)AND 31)=5 THEN A$=S$(Z%(A0,1))

    IF A$="def!" THEN GOTO EVAL_DEF
    IF A$="let*" THEN GOTO EVAL_LET
    IF A$="quote" THEN GOTO EVAL_QUOTE
    IF A$="quasiquote" THEN GOTO EVAL_QUASIQUOTE
    IF A$="do" THEN GOTO EVAL_DO
    IF A$="if" THEN GOTO EVAL_IF
    IF A$="fn*" THEN GOTO EVAL_FN
    GOTO EVAL_INVOKE

    EVAL_GET_A3:
      R=Z%(Z%(Z%(A,1),1),1)
      GOSUB VAL_R:A3=R
    EVAL_GET_A2:
      R=Z%(Z%(A,1),1)
      GOSUB VAL_R:A2=R
    EVAL_GET_A1:
      R=Z%(A,1)
      GOSUB VAL_R:A1=R
      RETURN

    EVAL_DEF:
      REM PRINT "def!"
      GOSUB EVAL_GET_A2: REM set A1 and A2

      Q=A1:GOSUB PUSH_Q
      A=A2:CALL EVAL: REM eval a2
      GOSUB POP_Q:A1=Q

      IF ER<>-2 THEN GOTO EVAL_RETURN

      REM set a1 in env to a2
      K=A1:C=R:GOSUB ENV_SET
      GOTO EVAL_RETURN

    EVAL_LET:
      REM PRINT "let*"
      GOSUB EVAL_GET_A2: REM set A1 and A2

      Q=A2:GOSUB PUSH_Q: REM push/save A2
      Q=E:GOSUB PUSH_Q: REM push env for for later release

      REM create new environment with outer as current environment
      C=E:GOSUB ENV_NEW
      E=R
      EVAL_LET_LOOP:
        IF Z%(A1,1)=0 THEN GOTO EVAL_LET_LOOP_DONE

        Q=A1:GOSUB PUSH_Q: REM push A1
        REM eval current A1 odd element
        A=Z%(A1,1):GOSUB VAL_A:CALL EVAL
        GOSUB POP_Q:A1=Q: REM pop A1

        IF ER<>-2 THEN GOTO EVAL_LET_LOOP_DONE

        REM set environment: even A1 key to odd A1 eval'd above
        K=Z%(A1+1,1):C=R:GOSUB ENV_SET
        AY=R:GOSUB RELEASE: REM release our use, ENV_SET took ownership

        REM skip to the next pair of A1 elements
        A1=Z%(Z%(A1,1),1)
        GOTO EVAL_LET_LOOP

      EVAL_LET_LOOP_DONE:
        GOSUB POP_Q:AY=Q: REM pop previous env

        REM release previous environment if not the current EVAL env
        GOSUB PEEK_Q_2
        IF AY<>Q THEN GOSUB RELEASE

        GOSUB POP_Q:A2=Q: REM pop A2
        A=A2:GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_DO:
      A=Z%(A,1): REM rest
      GOSUB PUSH_A: REM push/save A

      REM this must be EVAL_AST call #2 for EVAL_AST to return early
      REM and for TCO to work
      CALL EVAL_AST

      REM cleanup
      AY=R: REM get eval'd list for release

      GOSUB POP_A: REM pop/restore original A for LAST
      GOSUB LAST: REM get last element for return
      A=R: REM new recur AST

      REM cleanup
      GOSUB RELEASE: REM release eval'd list
      AY=A:GOSUB RELEASE: REM release LAST value (not sure why)

      GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_QUOTE:
      R=Z%(A,1):GOSUB VAL_R
      Z%(R,0)=Z%(R,0)+32
      GOTO EVAL_RETURN

    EVAL_QUASIQUOTE:
      R=Z%(A,1):GOSUB VAL_R
      A=R:CALL QUASIQUOTE
      A=R
      REM add quasiquote result to pending release queue to free when
      REM next lower EVAL level returns (LV)
      GOSUB PEND_A_LV

      GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_IF:
      GOSUB EVAL_GET_A1: REM set A1
      GOSUB PUSH_A: REM push/save A
      A=A1:CALL EVAL
      GOSUB POP_A: REM pop/restore A
      IF (R=0) OR (R=1) THEN GOTO EVAL_IF_FALSE

      EVAL_IF_TRUE:
        AY=R:GOSUB RELEASE
        GOSUB EVAL_GET_A2: REM set A1 and A2 after EVAL
        A=A2:GOTO EVAL_TCO_RECUR: REM TCO loop
      EVAL_IF_FALSE:
        AY=R:GOSUB RELEASE
        REM if no false case (A3), return nil
        GOSUB COUNT
        IF R<4 THEN R=0:Z%(R,0)=Z%(R,0)+32:GOTO EVAL_RETURN
        GOSUB EVAL_GET_A3: REM set A1 - A3 after EVAL
        A=A3:GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_FN:
      GOSUB EVAL_GET_A2: REM set A1 and A2
      A=A2:B=A1:GOSUB MAL_FUNCTION
      GOTO EVAL_RETURN

    EVAL_INVOKE:
      CALL EVAL_AST

      REM if error, return f/args for release by caller
      IF ER<>-2 THEN GOTO EVAL_RETURN

      REM push f/args for release after call
      GOSUB PUSH_R

      AR=Z%(R,1): REM rest
      GOSUB VAL_R:F=R

      REM if metadata, get the actual object
      IF (Z%(F,0)AND 31)>=16 THEN F=Z%(F,1)

      IF (Z%(F,0)AND 31)=9 THEN GOTO EVAL_DO_FUNCTION
      IF (Z%(F,0)AND 31)=10 THEN GOTO EVAL_DO_MAL_FUNCTION

      REM if error, pop and return f/args for release by caller
      GOSUB POP_R
      ER=-1:E$="apply of non-function":GOTO EVAL_RETURN

      EVAL_DO_FUNCTION:
        REM regular function
        IF Z%(F,1)<60 THEN GOSUB DO_FUNCTION:GOTO EVAL_DO_FUNCTION_SKIP
        REM for recur functions (apply, map, swap!), use GOTO
        IF Z%(F,1)>60 THEN CALL DO_TCO_FUNCTION
        EVAL_DO_FUNCTION_SKIP:

        REM pop and release f/args
        GOSUB POP_Q:AY=Q
        GOSUB RELEASE
        GOTO EVAL_RETURN

      EVAL_DO_MAL_FUNCTION:
        Q=E:GOSUB PUSH_Q: REM save the current environment for release

        REM create new environ using env stored with function
        C=Z%(F+1,1):A=Z%(F+1,0):B=AR:GOSUB ENV_NEW_BINDS

        REM release previous env if it is not the top one on the
        REM stack (X%(X-2)) because our new env refers to it and
        REM we no longer need to track it (since we are TCO recurring)
        GOSUB POP_Q:AY=Q
        GOSUB PEEK_Q_2
        IF AY<>Q THEN GOSUB RELEASE

        REM claim the AST before releasing the list containing it
        A=Z%(F,1):Z%(A,0)=Z%(A,0)+32
        REM add AST to pending release queue to free as soon as EVAL
        REM actually returns (LV+1)
        LV=LV+1:GOSUB PEND_A_LV:LV=LV-1

        REM pop and release f/args
        GOSUB POP_Q:AY=Q
        GOSUB RELEASE

        REM A set above
        E=R:GOTO EVAL_TCO_RECUR: REM TCO loop

  EVAL_RETURN:
    REM AZ=R: B=1: GOSUB PR_STR
    REM PRINT "EVAL_RETURN R: ["+R$+"] ("+STR$(R)+"), LV:"+STR$(LV)+",ER:"+STR$(ER)

    REM release environment if not the top one on the stack
    GOSUB PEEK_Q_1
    IF E<>Q THEN AY=E:GOSUB RELEASE

    LV=LV-1: REM track basic return stack level

    REM release everything we couldn't release earlier
    GOSUB RELEASE_PEND

    REM trigger GC
    #cbm T=FRE(0)
    #qbasic T=0

    REM pop A and E off the stack
    GOSUB POP_A
    GOSUB POP_Q:E=Q

END SUB

REM PRINT(A) -> R$
MAL_PRINT:
  AZ=A:B=1:GOSUB PR_STR
  RETURN

REM RE(A$) -> R
REM Assume D has repl_env
REM caller must release result
RE:
  R1=0
  GOSUB MAL_READ
  R1=R
  IF ER<>-2 THEN GOTO RE_DONE

  A=R:E=D:CALL EVAL

  RE_DONE:
    REM Release memory from MAL_READ
    IF R1<>0 THEN AY=R1:GOSUB RELEASE
    RETURN: REM caller must release result of EVAL

REM REP(A$) -> R$
REM Assume D has repl_env
SUB REP
  R1=-1:R2=-1
  GOSUB MAL_READ
  R1=R
  IF ER<>-2 THEN GOTO REP_DONE

  A=R:E=D:CALL EVAL
  R2=R
  IF ER<>-2 THEN GOTO REP_DONE

  A=R:GOSUB MAL_PRINT

  REP_DONE:
    REM Release memory from MAL_READ and EVAL
    AY=R2:GOSUB RELEASE
    AY=R1:GOSUB RELEASE
END SUB

REM MAIN program
MAIN:
  GOSUB INIT_MEMORY

  LV=0

  REM create repl_env
  C=0:GOSUB ENV_NEW:D=R

  REM core.EXT: defined in Basic
  E=D:GOSUB INIT_CORE_NS: REM set core functions in repl_env

  ZT=ZI: REM top of memory after base repl_env

  REM core.mal: defined using the language itself
  A$="(def! not (fn* (a) (if a false true)))"
  GOSUB RE:AY=R:GOSUB RELEASE

  A$="(def! load-file (fn* (f) (eval (read-file f))))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM load the args file
  A$="(def! -*ARGS*- (load-file "+CHR$(34)+".args.mal"+CHR$(34)+"))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM set the argument list
  A$="(def! *ARGV* (rest -*ARGS*-))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM get the first argument
  A$="(first -*ARGS*-)"
  GOSUB RE

  REM if there is an argument, then run it as a program
  IF R<>0 THEN AY=R:GOSUB RELEASE:GOTO RUN_PROG
  REM no arguments, start REPL loop
  IF R=0 THEN GOTO REPL_LOOP

  RUN_PROG:
    REM run a single mal program and exit
    A$="(load-file (first -*ARGS*-))"
    GOSUB RE
    IF ER<>-2 THEN GOSUB PRINT_ERROR
    GOTO QUIT

  REPL_LOOP:
    A$="user> ":GOSUB READLINE: REM call input parser
    IF EZ=1 THEN GOTO QUIT
    IF R$="" THEN GOTO REPL_LOOP

    A$=R$:CALL REP: REM call REP

    IF ER<>-2 THEN GOSUB PRINT_ERROR:GOTO REPL_LOOP
    PRINT R$
    GOTO REPL_LOOP

  QUIT:
    REM GOSUB PR_MEMORY_SUMMARY_SMALL
    END

  PRINT_ERROR:
    PRINT "Error: "+E$
    ER=-2:E$=""
    RETURN


#!/usr/bin/env python3
"""Bridge the production Mac DirectWire driver to the firmware host consumer through an OS-created PTY."""
import os,sys,tty,time,selectors,subprocess,tempfile,pathlib,json,argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--smoke',type=pathlib.Path,required=True)
parser.add_argument('--consumer',type=pathlib.Path,required=True)
parser.add_argument('--consumer-asan',type=pathlib.Path)
parser.add_argument('--fixture',type=pathlib.Path,required=True)
parser.add_argument('--output',type=pathlib.Path,required=True)
args=parser.parse_args()
base=args.output.resolve();base.mkdir(parents=True,exist_ok=True)
results=[]
for instrumented in ((False,True) if args.consumer_asan else (False,)):
  for show in (False,True):
    root=pathlib.Path(tempfile.mkdtemp(prefix='pico-direct-pty-',dir=str(base)))
    master,slave=os.openpty();tty.setraw(slave);port=os.ttyname(slave)
    consumer=args.consumer_asan if instrumented else args.consumer
    target=subprocess.Popen([str(consumer),str(root),'direct'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    cmd=[str(args.smoke.resolve()),'--pico-board-data-only','--pico-model-pty',port]
    if show:cmd+=['--pico-model-show']
    sender=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    mux=selectors.DefaultSelector();mux.register(master,selectors.EVENT_READ,'wire');mux.register(target.stdout,selectors.EVENT_READ,'reply');mux.register(sender.stdout,selectors.EVENT_READ,'sender');mux.register(sender.stderr,selectors.EVENT_READ,'error')
    sent=bytearray();replies=bytearray();output=bytearray();errors=bytearray();deadline=time.monotonic()+45
    try:
      while sender.poll() is None:
        if time.monotonic()>deadline:raise TimeoutError('PTY integration timed out')
        for key,_ in mux.select(.2):
          try:data=os.read(key.fd,65536)
          except OSError:
            mux.unregister(key.fileobj);continue
          if not data:mux.unregister(key.fileobj);continue
          if key.data=='wire':sent.extend(data);target.stdin.write(data);target.stdin.flush()
          elif key.data=='reply':replies.extend(data);os.write(master,data)
          elif key.data=='sender':output.extend(data)
          else:errors.extend(data)
      output.extend(sender.stdout.read());errors.extend(sender.stderr.read())
      target.stdin.close();target.wait(timeout=5);target_error=target.stderr.read()
      fixture=args.fixture.read_bytes()
      matches=[str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p.read_bytes()==fixture]
      result={'asan':instrumented,'show':show,'sender_exit':sender.returncode,'consumer_exit':target.returncode,'payload_bytes':len(fixture),'matching_persisted_files':matches,'wire_bytes':len(sent),'reply_bytes':len(replies),'stdout':output.decode(errors='replace'),'stderr':errors.decode(errors='replace'),'consumer_stderr':target_error.decode(errors='replace')}
      (root/'production-wire.bin').write_bytes(sent);(root/'production-replies.txt').write_bytes(replies)
      results.append(result)
      print(json.dumps(result,ensure_ascii=False),flush=True)
      assert sender.returncode==0 and target.returncode==0 and matches and not errors and not target_error
      assert b'RPICO BOARD BEGINMODEL canvas ' in sent and b'RPICO BOARD CHUNK ' in sent and b'RPICO BOARD COMMIT ' in sent
      assert (b'"state":"displayed"' if show else b'"state":"saved"') in replies
    finally:
      mux.close();os.close(master);os.close(slave)
      if sender.poll() is None:sender.kill();sender.wait()
      if target.poll() is None:target.kill();target.wait()
(base/'pty-integration-report.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')

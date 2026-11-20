const qaRequire=require('node:module').createRequire(require('node:path').resolve('.dart_tool/qa-browser/package.json'));
const {chromium}=qaRequire('playwright'),fs=require('fs'),assert=require('node:assert/strict');
process.env.FIRESTORE_EMULATOR_HOST='127.0.0.1:8180';process.env.FIREBASE_AUTH_EMULATOR_HOST='127.0.0.1:9099';
const {initializeApp:adminApp}=qaRequire('firebase-admin/app'),{getFirestore}=qaRequire('firebase-admin/firestore');adminApp({projectId:'demo-roadsense-qa'});
const {initializeApp}=qaRequire('firebase/app'),authSdk=qaRequire('firebase/auth'),dbSdk=qaRequire('firebase/firestore');
const account=JSON.parse(fs.readFileSync('.dart_tool/qa-browser/accounts.json','utf8'));
const classes=[[0,'Pothole','CODE 01'],[1,'Alligator crack','CODE 02'],[3,'Longitudinal crack','CODE 12'],[4,'Transverse crack','CODE 12']];
const results=[];
async function check(name,fn){try{await fn();results.push({name,passed:true});console.log('PASS '+name)}catch(e){results.push({name,passed:false,error:e.message});console.log('FAIL '+name+' '+e.message.slice(0,180))}}
(async()=>{
 const adminDb=getFirestore(),app=initializeApp({projectId:'demo-roadsense-qa',apiKey:'demo-key',appId:'1:32297924997:web:qa'}),auth=authSdk.getAuth(app),db=dbSdk.getFirestore(app);
 authSdk.connectAuthEmulator(auth,'http://127.0.0.1:9099',{disableWarnings:true});dbSdk.connectFirestoreEmulator(db,'127.0.0.1',8180);
 await authSdk.signInWithEmailAndPassword(auth,account.email,account.password);
 function payload([id,name,code]){return {latitude:14.85,longitude:120.81,imageUrl:'',status:'pending',overallSeverity:'medium',potholeCount:1,primaryClassId:id,primaryDefect:name,primaryDpwhCode:code,modelId:'dpwh-package6',reporterUid:account.uid,reporterEmail:account.email,reporterName:'Model QA',reporterPhotoUrl:'',detections:[],timestamp:dbSdk.serverTimestamp()}}
 for(const cls of classes){await adminDb.doc('potholes/qa-model-'+cls[0]).delete();await check('create supported class '+cls[1],()=>dbSdk.setDoc(dbSdk.doc(db,'potholes','qa-model-'+cls[0]),payload(cls)))}
 for(const cls of [[2,'Depression','CODE 05'],[5,'Edge break','CODE 01'],[3,'Transverse crack','CODE 12']]){
  await check('reject unsupported/mismatched '+JSON.stringify(cls),()=>assert.rejects(dbSdk.addDoc(dbSdk.collection(db,'potholes'),payload(cls))));
 }
 await adminDb.doc('potholes/qa-model-legacy').set({...payload([2,'Depression','CODE 05']),timestamp:new Date(),status:'approved'});
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1440,height:1000}});page.setDefaultTimeout(15000);const errors=[];page.on('pageerror',e=>errors.push(e.stack));
 await page.goto('http://localhost:8081');await page.getByText('Running in emulator mode. Do not use with production credentials.',{exact:true}).waitFor();await page.locator('flt-semantics-placeholder').evaluate(e=>e.click());
 for(const [name,value] of [['Email Address',account.adminEmail],['Password',account.adminPassword]]){const input=page.getByRole('textbox',{name,exact:true});await input.click();await input.fill('');await page.keyboard.type(value,{delay:10});await page.keyboard.press('Tab');}
 await page.getByRole('button',{name:'Sign In to Portal',exact:true}).click();await page.getByRole('button',{name:'Overview',exact:true}).waitFor();
 await check('overview excludes depression from the trained-class breakdown',async()=>{const snapshot=await page.locator('body').ariaSnapshot();assert.match(snapshot,/Four trained classes/);assert.doesNotMatch(snapshot,/Depression SLA/);});
 await page.getByRole('button',{name:/^Pending review/}).click();
 await check('four separate admin class filters',async()=>{for(const [id,name,code] of classes)assert.equal(await page.getByRole('button',{name:new RegExp('^'+code+': '+name)}).count(),1);assert.equal(await page.getByRole('button',{name:/^Code 05: Depression/}).count(),0);});
 await page.getByRole('button',{name:/^CODE 12: Longitudinal crack/}).click();await page.getByRole('button',{name:'Edit',exact:true}).first().click();
 await check('both Code 12 classes are selectable and save independently',async()=>{
  await page.getByText('CODE 12: Longitudinal crack (Routine maintenance / sealing)',{exact:true}).last().click();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await page.getByRole('button',{name:'Save Changes',exact:true}).click();
  await page.waitForTimeout(700);const report=(await adminDb.doc('potholes/qa-model-3').get()).data();
  assert.equal(report.primaryClassId,4);assert.equal(report.primaryDefect,'Transverse crack');assert.equal(report.primaryDpwhCode,'CODE 12');assert.equal(report.overallSeverity,'medium');
 });
 await page.screenshot({path:'docs/model-alignment-admin.png'});await check('no browser page exceptions',()=>assert.deepEqual(errors,[]));
 await browser.close();fs.writeFileSync('docs/model-alignment-results.json',JSON.stringify({project:'demo-roadsense-qa',results,errors},null,2));process.exit(results.every(r=>r.passed)?0:1);
})().catch(e=>{console.error(e.message);process.exit(1)});

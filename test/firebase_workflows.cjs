// Run against firebase.qa.json only; never grants roles in a live project.
const base='../.dart_tool/qa-browser/node_modules/';
const {initializeApp}=require(base+'firebase/app');
const authSdk=require(base+'firebase/auth');
const dbSdk=require(base+'firebase/firestore');
const assert=require('node:assert/strict');
const fs=require('node:fs');
process.env.FIREBASE_AUTH_EMULATOR_HOST='127.0.0.1:9099';
process.env.FIRESTORE_EMULATOR_HOST='127.0.0.1:8180';
const qaRequire=require('node:module').createRequire(require('node:path').resolve('.dart_tool/qa-browser/package.json'));
const admin=qaRequire('firebase-admin/app');
const {getAuth: adminAuth}=qaRequire('firebase-admin/auth');
const {getFirestore: adminFirestore}=qaRequire('firebase-admin/firestore');
admin.initializeApp({projectId:'demo-roadsense-qa'});
const results=[];
const password='Qa-local-only-123!';
function client(name){
 const app=initializeApp({projectId:'demo-roadsense-qa',apiKey:'demo-key',appId:'1:32297924997:web:qa'},name);
 const auth=authSdk.getAuth(app);authSdk.connectAuthEmulator(auth,'http://127.0.0.1:9099',{disableWarnings:true});
 const db=dbSdk.getFirestore(app);dbSdk.connectFirestoreEmulator(db,'127.0.0.1',8180);return {app,auth,db};
}
async function check(name,fn){try{await fn();results.push({name,passed:true});console.log('PASS '+name)}catch(e){results.push({name,passed:false,error:e.code||e.message});console.log('FAIL '+name+' '+(e.code||e.message))}}
async function codes(){return (await (await fetch('http://127.0.0.1:9099/emulator/v1/projects/demo-roadsense-qa/oobCodes')).json()).oobCodes||[]}
(async()=>{
 const run=Date.now(); const user=client('user'+run),moderator=client('admin'+run),other=client('other'+run);
 const email=`qa.user.${run}@example.test`,adminEmail=`qa.admin.${run}@example.test`;
 let uid,adminUid,report;
 await check('register user and create profile',async()=>{
  uid=(await authSdk.createUserWithEmailAndPassword(user.auth,email,password)).user.uid;
  await dbSdk.setDoc(dbSdk.doc(user.db,'users',uid),{uid,email,displayName:'QA Surveyor',role:'user'});
 });
 await check('logout and email login',async()=>{
  await authSdk.signOut(user.auth);assert.equal(user.auth.currentUser,null);
  assert.equal((await authSdk.signInWithEmailAndPassword(user.auth,email,password)).user.uid,uid);
 });
 await check('reject wrong password',()=>assert.rejects(authSdk.signInWithEmailAndPassword(user.auth,email,'wrong-password')));
 await check('verification email action link',async()=>{
  await authSdk.sendEmailVerification(user.auth.currentUser);
  const code=(await codes()).findLast(c=>c.email===email&&c.requestType==='VERIFY_EMAIL');assert.ok(code);
  await authSdk.applyActionCode(user.auth,code.oobCode);await authSdk.reload(user.auth.currentUser);assert.equal(user.auth.currentUser.emailVerified,true);
 });
 await check('password reset action and new-password login',async()=>{
  await authSdk.sendPasswordResetEmail(user.auth,email);
  const code=(await codes()).findLast(c=>c.email===email&&c.requestType==='PASSWORD_RESET');assert.ok(code);
  await authSdk.confirmPasswordReset(user.auth,code.oobCode,password+'new');
  await authSdk.signOut(user.auth);await authSdk.signInWithEmailAndPassword(user.auth,email,password+'new');
 });
 await check('profile editing persists',async()=>{
  await dbSdk.updateDoc(dbSdk.doc(user.db,'users',uid),{firstName:'Updated',lastName:'Surveyor',phoneNumber:'09000000000'});
  assert.equal((await dbSdk.getDoc(dbSdk.doc(user.db,'users',uid))).data().firstName,'Updated');
 });
 await check('create local admin fixture',async()=>{
  adminUid=(await authSdk.createUserWithEmailAndPassword(moderator.auth,adminEmail,password)).user.uid;
  await adminAuth().updateUser(adminUid,{emailVerified:true});
  await adminFirestore().doc('users/'+adminUid).set({uid:adminUid,email:adminEmail,displayName:'QA Admin',role:'admin'});
  await moderator.auth.currentUser.getIdToken(true);
 });
 await check('user cannot promote own role',()=>assert.rejects(dbSdk.updateDoc(dbSdk.doc(user.db,'users',uid),{role:'admin'})));
 await check('submit report with app schema',async()=>{
  report=await dbSdk.addDoc(dbSdk.collection(user.db,'potholes'),{
   latitude:14.85,longitude:120.81,imageUrl:'https://potholestorage2026.blob.core.windows.net/photos/qa-fixture.jpg',status:'pending',overallSeverity:'medium',potholeCount:1,
   primaryDpwhCode:'CODE 01',primaryDefect:'Pothole',responseTime:'3 Days',correctiveMeasure:'QA fixture',detections:[],barangay:'Bagna',city:'Malolos',province:'Bulacan',formattedAddress:'QA fixture',
   reporterUid:uid,reporterEmail:email,reporterName:'QA Surveyor',reporterPhotoUrl:'',timestamp:dbSdk.serverTimestamp()
  });
 });
 await check('edit own pending report',async()=>{
  assert.ok(report);await dbSdk.updateDoc(report,{note:'QA edited',overallSeverity:'high',lastEditedAt:dbSdk.serverTimestamp(),lastEditedBy:email});
 });
 await check('trash and restore own pending report',async()=>{
  assert.ok(report);await dbSdk.updateDoc(report,{status:'deleted',previousStatus:'pending',deletedAt:dbSdk.serverTimestamp(),deletedBy:email});
  await dbSdk.updateDoc(report,{status:'pending',restoredAt:dbSdk.serverTimestamp(),restoredBy:email});assert.equal((await dbSdk.getDoc(report)).data().status,'pending');
 });
 await check('user cannot approve report',async()=>{assert.ok(report);await assert.rejects(dbSdk.updateDoc(report,{status:'approved'}));});
 await check('admin approval and approved-map query',async()=>{
  assert.ok(report);await dbSdk.updateDoc(dbSdk.doc(moderator.db,'potholes',report.id),{status:'approved',moderatedBy:adminUid,moderatedAt:dbSdk.serverTimestamp()});
  const rows=await dbSdk.getDocs(dbSdk.query(dbSdk.collection(user.db,'potholes'),dbSdk.where('status','==','approved')));assert.ok(rows.docs.some(d=>d.id===report.id));
 });
 await check('report owner cannot delete approved report',async()=>{assert.ok(report);await assert.rejects(dbSdk.deleteDoc(report));});
 await check('other user cannot edit or delete report',async()=>{
  assert.ok(report);await authSdk.createUserWithEmailAndPassword(other.auth,`qa.other.${run}@example.test`,password);
  await assert.rejects(dbSdk.updateDoc(dbSdk.doc(other.db,'potholes',report.id),{note:'unauthorized'}));await assert.rejects(dbSdk.deleteDoc(dbSdk.doc(other.db,'potholes',report.id)));
 });
 await check('admin trash restore and permanent delete',async()=>{
  assert.ok(report);const ref=dbSdk.doc(moderator.db,'potholes',report.id);
  await dbSdk.updateDoc(ref,{status:'deleted',previousStatus:'approved'});await dbSdk.updateDoc(ref,{status:'approved'});await dbSdk.deleteDoc(ref);assert.equal((await dbSdk.getDoc(ref)).exists(),false);
 });
 await check('Google provider credential through Auth emulator',async()=>{
  const account=client('google'+run);
  const credential=authSdk.GoogleAuthProvider.credential(JSON.stringify({sub:'qa-google-'+run,email:`qa.google.${run}@example.test`,email_verified:true}));
  const result=await authSdk.signInWithCredential(account.auth,credential);assert.equal(result.user.providerData[0].providerId,'google.com');await authSdk.signOut(account.auth);
 });
 fs.writeFileSync('docs/qa-firebase-workflows.json',JSON.stringify({project:'demo-roadsense-qa',results},null,2));
 fs.writeFileSync('.dart_tool/qa-browser/accounts.json',JSON.stringify({email,password:password+'new',uid,adminEmail,adminPassword:password,adminUid}));
 console.log(JSON.stringify({passed:results.filter(x=>x.passed).length,failed:results.filter(x=>!x.passed).length}));process.exit(results.every(x=>x.passed)?0:1);
})().catch(e=>{console.error(e.message);process.exit(1)});

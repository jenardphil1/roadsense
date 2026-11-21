const {chromium}=require('../.dart_tool/qa-browser/node_modules/playwright');
const fs=require('fs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 const results=[];
 for(const [width,height,scheme] of [[1440,900,'light'],[375,812,'light'],[812,375,'light'],[1440,900,'dark'],[375,812,'dark']]){
  const context=await browser.newContext({viewport:{width,height},colorScheme:scheme});
  const page=await context.newPage();const errors=[];
  page.on('pageerror',e=>errors.push(e.stack));
  page.on('console',m=>{if(m.type()==='error')errors.push(m.text())});
  const result={width,height,scheme,errors,checks:[]};
  try{
   await page.goto(process.env.QA_BASE_URL || 'http://localhost:8080');
   await page.locator('flt-semantics-placeholder').evaluate(e=>e.click());
   await page.getByRole('button',{name:'Sign In to Portal',exact:true}).waitFor({timeout:20000});
   await page.screenshot({path:`docs/qa-web-${width}-${height}-${scheme}.png`});
   result.checks.push('login rendered');
   await page.getByRole('button',{name:'Sign In to Portal',exact:true}).click();
   await page.getByText('Enter a valid email address',{exact:true}).last().waitFor();
   await page.getByText('Please enter a password',{exact:true}).last().waitFor();
   result.checks.push('empty login rejected inline');
   await page.getByRole('button',{name:'Register',exact:true}).focus();
   await page.keyboard.press('Enter');
   await page.getByRole('button',{name:'Create Account & Verify Email',exact:true}).click();
   await page.getByRole('textbox',{name:'First Name',exact:true}).waitFor();
   await page.getByText('Please confirm your password',{exact:true}).last().waitFor();
   result.checks.push('registration opens and empty submission stays on form');
   await page.screenshot({path:`docs/qa-web-register-${width}-${height}-${scheme}.png`});
   result.registration=await page.locator('body').ariaSnapshot();
   await page.getByRole('button',{name:'Sign In',exact:true}).click();
   await page.getByRole('button',{name:'Forgot Password?',exact:true}).click();
   await page.getByRole('button',{name:'Send Reset Link',exact:true}).waitFor();
   await page.getByRole('button',{name:'Cancel',exact:true}).click();
   result.checks.push('password reset dialog opens and cancels');
   if(width>=900){
    await page.getByRole('button',{name:'Zoom in',exact:true}).click();
    await page.getByRole('button',{name:'Zoom out',exact:true}).click();
    await page.getByRole('button',{name:'Recenter Sector Bulacan',exact:true}).press('Enter');
    result.checks.push('map zoom and recenter controls respond without new page exception');
   }else{
    await page.getByRole('button',{name:'Explore Map',exact:true}).click();
    await page.getByRole('button',{name:'Back to Sign In',exact:true}).waitFor();
    await page.getByRole('button',{name:'Back to Sign In',exact:true}).press('Enter');
    await page.getByRole('button',{name:'Sign In to Portal',exact:true}).waitFor();
    result.checks.push('public map exploration opens and returns to login');
   }
  }catch(e){result.failure=e.message;await page.screenshot({path:`docs/qa-web-failure-${width}-${scheme}.png`}).catch(()=>{});}
  results.push(result);console.log(JSON.stringify({...result,registration:undefined}));
  await context.close();
 }
 fs.writeFileSync('docs/qa-web-smoke-results.json',JSON.stringify(results,null,2));
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});


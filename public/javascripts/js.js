$(document).ready(function(){

   var options = { 
     target:        '#response',   
     beforeSubmit:  validate,  
   };

   $('#signup').submit(function() { 
     $(this).ajaxSubmit(options); 
     return false; 
   });

});

function validate(formData, jqForm, options){
   var form = jqForm[0]; 
   var return_value = true;
   var emailReg = /^([\w-\.]+@([\w-]+\.)+[\w-]{2,4})?$/;
    
   if(!form.name.value){
      $('#name_error').show('slow');
      return_value = false;
   }else{
      $('#name_error').hide('slow');
   }
   
   //email validation
   if(!form.email.value){
      $('#email_error').css('display', 'block');
      $('#email_ongeldig_error').css('display', 'none');
      return_value = false;
   }else {
      if(!emailReg.test(form.email.value)){
         $('#email_ongeldig_error').css('display', 'block');
         $('#email_error').css('display', 'none');
         return_value = false;
      }else{
         $('#email_error').css('display', 'none');
         $('#email_ongeldig_error').css('display', 'none');
      }	
   }

   if(!form.password.value){
      $('#password_error').show('slow');
      return_value = false;
   }else{
      $('#password_error').hide('slow');
   }

   if(form.password2.value != form.password.value){
      $('#password2_error').show('slow');
      return_value = false;
   }else{
      $('#password2_error').hide('slow');
   }
   return return_value;
}

function IsNumeric(input)
{
   return (input - 0) == input && input.length > 0;
}

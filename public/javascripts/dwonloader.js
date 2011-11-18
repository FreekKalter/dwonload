$(document).ready(function(){
   $('#upload-form').ajaxForm({beforeSubmit: validate});
});

function validate(formData, jqForm, options) { 
   var form = jqForm[0];
   var return_value = true;
   if(!form.datafile.value){
      $('#datafile').addClass('error');
      $('#datafile-container').addClass('error');
      $('#datafile-help').fadeIn('slow');
      return_value = false;
   }else{
      $('#datafile-help').fadeOut('slow');
      $('#datafile').removeClass('error');
      $('#datafile-container').removeClass('error');

   }

   var friends = $('input[name=shared]').fieldValue();
   if(friends == ""){
      $('#friends').addClass('error');
      $('#friends-container').addClass('error');
      $('#friends-help').fadeIn('slow');
      return_value = false;
   }else{
      $('#friends-help').fadeOut('slow');
      $('#friends').removeClass('error');
      $('#friends-container').removeClass('error');
   }
   if(!return_value){
      return false;
   }
}

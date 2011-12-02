$(document).ready(function(){
   $('#upload-form').ajaxForm({beforeSubmit: validate});

   var tabs = new Array();
   tabs["#shared"] = "/me/files_i_shared";
   tabs["#others"] = "/me/files_shared_with_me";
   tabs["#upload"] = "/me/friends_upload_form"; 

   $('.tabs').bind('change', function (e) {
      var regex =/#\w*/gi;
      var div =   e.target.href.match(regex);
      $(div + '-inner').load(tabs[div]);
   });

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
   }else{
      function friend(name, fb_id){
         this.name = name;
         this.fb_id = fb_id;
      }

      var friendsObj = new Array();

      $('label.check').each(function(index){
         if( $(this).find('input').attr('checked')){
            var fb_id = $(this).find('input').attr("value");
            var name = $(this).find('span').text();
            tmpFriend = new friend(name, fb_id);
            friendsObj.push(tmpFriend);
         }
      });
      console.log(friendsObj);
      console.log(JSON.stringify(friendsObj));
      $.post('/add_friends', {friends: JSON.stringify(friendsObj)} );
   }
}

$(document).ready(function(){
   $('#upload-form').ajaxForm({beforeSubmit: validate});

   var tabs = {}; //create an empty object
   tabs["#shared"] = "/me/files_i_shared";
   tabs["#others"] = "/me/files_shared_with_me";
   tabs["#upload"] = "/me/friends_upload_form"; 

   //TODO: make it match "others#_=_" OR dont make this messy shit appear at all ;-)
   var tab = window.location.href.match(/(\w*)$/)[0];
   $("#" + tab + '-inner').load(tabs["#" + tab]);

   window.onpopstate = function(event){
      console.log(event);
      if(event.state){
         window.location = document.location.href;
      }
   }

   $('.tabs').bind('change', function (e) {
      var regex =/#\w*/gi;
      var div =  e.target.href.match(regex);
      $(div + '-inner').load(tabs[div]);
      var stateObj = { tab: div };
      history.pushState(stateObj, div, "/me/" + div.toString().substring(1));
      history.replaceState(stateObj, div, "/me/" + div.toString().substring(1));
   });


   $('.details_link').live('click', function(event){
      //add a row with details about the file
      var strip = /(.*)\?/gi;
      var link = $(this).attr("href").match(strip).toString();
      var clicked_row = $(this).closest('tr');
      link = link.substring(0, link.length-1);

      var found = $('.tab-content').find('#details_result_row');
      if(found.length > 0){
         $("#details_result_column").animate({
            opacity: 0.20,
            height: 'toggle'
         }, 500 ,function(){
            $('#details_result_row').remove();
            $(clicked_row).after('<tr id="details_result_row"><td id="details_result_column"></td><td> </td></tr>'); //prepare row
            $("#details_result_column").load(link, function(){  //load ajax details
               $('#details_result_row').slideDown(500);
            });
         });
      }else{
         $(this).closest('tr').after('<tr id="details_result_row"><td id="details_result_column"></td><td> </td></tr>'); //prepare row
         $("#details_result_column").load(link, function(){  //load ajax details
            $('#details_result_row').slideDown(500);
         });
      }
      return false;
   });

});

function jqCheckAll( id, pID ) {
 console.log(id);
   console.log($('#' + id).is(':checked'));
    $( "#" + pID + " :checkbox").attr('checked', $('#' + id).is(':checked'));
}

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

      //send friends names asynchronius from upload
      function friend(name, fb_id){
         this.name = name;
         this.fb_id = fb_id;
      }

      var friendsObj = new Array(); //array of friend objects

      //added checked friends to array
      $('label.check').each(function(index){
         if( $(this).find('input').attr('checked')){
            var fb_id = $(this).find('input').attr("value");
            var name = $(this).find('span').text();
            tmpFriend = new friend(name, fb_id);
            friendsObj.push(tmpFriend);
         }
      });
      $.post('/add_friends', {friends: JSON.stringify(friendsObj)} );
      return true;
   }
}

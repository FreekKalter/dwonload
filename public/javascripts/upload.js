 interval = null;

function openProgressBar() {
    /* generate random progress-id */
    uuid = "";
    for (i = 0; i < 32; i++) {
     uuid += Math.floor(Math.random() * 16).toString(16);
    }
    /* patch the form-action tag to include the progress-id */
    console.log('net gemaakt: ' + uuid);
    document.getElementById("upload-form").action="/upload?X-Progress-ID=" + uuid;

    $('#progress').slideDown('slow');
    $('img.ajax-loader').fadeIn('slow');
    /* call the progress-updater every 1000ms */
    interval = window.setInterval(
      function () {
        fetch(uuid);
      },
      5000
    );
}

function fetch(uuid) {
 var req = createInstance();
 req.onreadystatechange = function () {
    console.log('ready state change (' +  req.readyState + ')');
  if (req.readyState == 4) {
   if (req.status == 200) {
    /* poor-man JSON parser */
    var upload = eval( "(" + req.responseText + ")");

    document.getElementById('tp').innerHTML = upload.state;

    /* change the width if the inner progress-bar */
    if (upload.state == 'uploading') {
     bar = document.getElementById('progressbar');
     w = bar_width * upload.received / upload.size;
     bar.style.width = w + 'px';
    }
    /* we are done, stop the interval */
    if (upload.state == 'done') {
       bar.style.width = bar_width;
        window.clearTimeout(interval);
//        setTimeout("window.location.href = '/me/shared'", 20000);
    }
   }
  }
 }

 var bar_width = 300;
 console.log('req.open: ' + req.open("GET", "/progress", true));
 req.setRequestHeader("X-Progress-ID", uuid);
 console.log('req.send ' + uuid + ': ' + req.send(null));
}

function createInstance(){
   if(window.XMLHttpRequest){
      req = new XMLHttpRequest();
   }else
      aler('Kut');
   return req;
}

function trim(value) {
  value = value.replace(/^\s+/,'');
  value = value.replace(/\s+$/,'');
  return value;
}

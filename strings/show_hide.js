window.onload = function(e)
{
    console.log( "onload" );
    var elems = document.querySelectorAll( "div.toc ul ul" );
    for( i in elems )
        elems[i].style.display = "none";
}

function show_hide(id) 
{ 
    var elem = document.getElementById( id ); 
    if( elem.style.display == "block" ) 
        elem.style.display = "none"; 
    else elem.style.display = "block"; 
}
